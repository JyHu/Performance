//
//  cperf_unwind.c
//  寄存器读取与帧指针链展开。
//

#include "include/cperf_backtrace.h"

#include <pthread.h>
#include <string.h>
#include <mach/mach.h>

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

#pragma mark - 架构抽象

#if defined(__arm64__) || defined(__aarch64__)

typedef arm_thread_state64_t cperf_thread_state_t;
#define CPERF_THREAD_STATE_FLAVOR ARM_THREAD_STATE64
#define CPERF_THREAD_STATE_COUNT  ARM_THREAD_STATE64_COUNT

static void cperf_extract_registers(const cperf_thread_state_t *state, cperf_registers_t *out) {
    // arm64e 上 pc/lr 带指针认证签名，必须剥掉后才是可用地址。
    // 这两个 getter 宏在非 ptrauth 平台上退化为直接取字段。
    out->pc = (uint64_t)arm_thread_state64_get_pc(*state);
    out->lr = (uint64_t)arm_thread_state64_get_lr(*state);
    out->sp = (uint64_t)arm_thread_state64_get_sp(*state);
    out->fp = (uint64_t)arm_thread_state64_get_fp(*state);
}

#elif defined(__x86_64__)

typedef x86_thread_state64_t cperf_thread_state_t;
#define CPERF_THREAD_STATE_FLAVOR x86_THREAD_STATE64
#define CPERF_THREAD_STATE_COUNT  x86_THREAD_STATE64_COUNT

static void cperf_extract_registers(const cperf_thread_state_t *state, cperf_registers_t *out) {
    out->pc = state->__rip;
    // x86_64 没有链接寄存器：返回地址一律在栈上
    out->lr = 0;
    out->sp = state->__rsp;
    out->fp = state->__rbp;
}

#else
#define CPERF_UNSUPPORTED_ARCH 1
#endif

/// 剥掉返回地址上的指针认证签名。
///
/// arm64e 上从栈里读出的返回地址是带签名的，直接当地址用会指向无效内存，
/// 符号化时表现为「全是乱七八糟的地址」。
static uint64_t cperf_strip_pointer(uint64_t pointer) {
#if __has_feature(ptrauth_calls)
    return (uint64_t)(uintptr_t)ptrauth_strip((void *)(uintptr_t)pointer, ptrauth_key_return_address);
#else
    return pointer;
#endif
}

#pragma mark - 安全读取

/// 从当前进程读取一段内存，地址无效时返回失败而不是触发 SIGSEGV。
///
/// 为什么不直接解引用：帧指针链来自被观测线程的栈，而我们回溯的场景
/// 恰恰是「这个线程出问题了」——栈可能已被踩坏。直接解引用一个坏 fp
/// 会让采集线程自己崩掉，把一次可排查的卡顿变成一次崩溃。
static bool cperf_read_memory(uint64_t address, void *destination, size_t size) {
    vm_size_t read_size = (vm_size_t)size;
    kern_return_t result = vm_read_overwrite(
        mach_task_self(),
        (vm_address_t)address,
        (vm_size_t)size,
        (vm_address_t)destination,
        &read_size
    );
    return result == KERN_SUCCESS && read_size == (vm_size_t)size;
}

/// 栈帧在内存中的布局。
///
/// arm64 与 x86_64 在启用帧指针时布局一致：
/// `[fp]` 是调用者的 fp，`[fp + 8]` 是返回地址。
typedef struct {
    uint64_t caller_fp;
    uint64_t return_address;
} cperf_frame_t;

/// 目标线程的栈范围，用于校验帧指针。
typedef struct {
    uint64_t low;
    uint64_t high;
    bool known;
} cperf_stack_bounds_t;

static cperf_stack_bounds_t cperf_stack_bounds(mach_port_t thread) {
    cperf_stack_bounds_t bounds = { 0, 0, false };

    pthread_t handle = pthread_from_mach_thread_np(thread);
    if (handle == NULL) {
        return bounds;
    }
    // pthread_get_stackaddr_np 返回栈**高**地址端（栈向低地址增长）
    uint64_t top = (uint64_t)(uintptr_t)pthread_get_stackaddr_np(handle);
    size_t size = pthread_get_stacksize_np(handle);
    if (top == 0 || size == 0) {
        return bounds;
    }

    bounds.high = top;
    bounds.low = top - (uint64_t)size;
    bounds.known = true;
    return bounds;
}

static bool cperf_is_plausible_frame_pointer(uint64_t fp, uint64_t previous_fp, cperf_stack_bounds_t bounds) {
    if (fp == 0) {
        return false;
    }
    // 帧指针必须按指针宽度对齐
    if ((fp & (sizeof(void *) - 1)) != 0) {
        return false;
    }
    // 栈向低地址增长，向上回溯时 fp 必须严格递增。
    // 这条同时也是环检测：踩坏的栈很容易形成自指的帧链，
    // 没有这个检查就会在这里无限循环。
    if (previous_fp != 0 && fp <= previous_fp) {
        return false;
    }
    if (bounds.known && (fp < bounds.low || fp >= bounds.high)) {
        return false;
    }
    return true;
}

#pragma mark - 回溯

/// 已拿到寄存器后的展开过程。抽出来是为了让崩溃现场能直接复用
/// signal handler 传入的 ucontext 寄存器，不必再 thread_get_state。
static void cperf_unwind_from_registers(
    mach_port_t thread,
    const cperf_registers_t *registers,
    cperf_backtrace_t *out
) {
    out->registers = *registers;
    out->frame_count = 0;
    out->truncated = false;

    if (registers->pc == 0) {
        return;
    }
    out->frames[out->frame_count++] = registers->pc;

    cperf_stack_bounds_t bounds = cperf_stack_bounds(thread);

    uint64_t link_register = cperf_strip_pointer(registers->lr);
    uint64_t current_fp = registers->fp;
    uint64_t previous_fp = 0;
    bool link_register_consumed = false;

    while (out->frame_count < CPERF_MAX_FRAMES) {
        if (!cperf_is_plausible_frame_pointer(current_fp, previous_fp, bounds)) {
            break;
        }

        cperf_frame_t frame;
        if (!cperf_read_memory(current_fp, &frame, sizeof(frame))) {
            break;
        }

        uint64_t return_address = cperf_strip_pointer(frame.return_address);
        if (return_address == 0) {
            break;
        }

        // arm64 叶子函数还没把 lr 压栈，调用者只能从 lr 拿到。
        // 但非叶子函数的 lr 会与帧链第一项重复，所以只在不重复时补。
        if (!link_register_consumed) {
            link_register_consumed = true;
            if (link_register != 0
                && link_register != return_address
                && link_register != registers->pc) {
                out->frames[out->frame_count++] = link_register;
                if (out->frame_count >= CPERF_MAX_FRAMES) {
                    out->truncated = true;
                    break;
                }
            }
        }

        out->frames[out->frame_count++] = return_address;

        previous_fp = current_fp;
        current_fp = frame.caller_fp;
    }

    if (out->frame_count >= CPERF_MAX_FRAMES) {
        out->truncated = true;
    }
}

kern_return_t cperf_backtrace_thread(mach_port_t thread, cperf_backtrace_t *out) {
    if (out == NULL) {
        return KERN_INVALID_ARGUMENT;
    }
    memset(out, 0, sizeof(*out));

#ifdef CPERF_UNSUPPORTED_ARCH
    (void)thread;
    return KERN_NOT_SUPPORTED;
#else
    if (thread == MACH_PORT_NULL) {
        return KERN_INVALID_ARGUMENT;
    }

    // 挂起自己会永久卡死——没有别的线程能来恢复它。
    //
    // 用 pthread_mach_thread_np 而不是 mach_thread_self()：后者返回一个
    // 需要 mach_port_deallocate 配对释放的 send right，在高频采集路径上
    // 漏一次就是一次端口泄漏。
    bool is_self = (thread == pthread_mach_thread_np(pthread_self()));
    if (!is_self) {
        kern_return_t suspend_result = thread_suspend(thread);
        if (suspend_result != KERN_SUCCESS) {
            return suspend_result;
        }
    }

    cperf_thread_state_t state;
    mach_msg_type_number_t state_count = CPERF_THREAD_STATE_COUNT;
    kern_return_t state_result = thread_get_state(
        thread,
        CPERF_THREAD_STATE_FLAVOR,
        (thread_state_t)&state,
        &state_count
    );

    if (state_result == KERN_SUCCESS) {
        cperf_registers_t registers;
        cperf_extract_registers(&state, &registers);
        cperf_unwind_from_registers(thread, &registers, out);
    }

    if (!is_self) {
        // 无论回溯成功与否都必须恢复。漏掉这一步会让目标线程永久挂起，
        // 如果那是主线程，app 就彻底僵死了——监控本身造成的死锁。
        thread_resume(thread);
    }

    return state_result;
#endif
}

kern_return_t cperf_backtrace_main_thread(cperf_backtrace_t *out) {
    mach_port_t main_thread = cperf_main_thread_port();
    if (main_thread == MACH_PORT_NULL) {
        if (out != NULL) {
            memset(out, 0, sizeof(*out));
        }
        return KERN_FAILURE;
    }
    return cperf_backtrace_thread(main_thread, out);
}
