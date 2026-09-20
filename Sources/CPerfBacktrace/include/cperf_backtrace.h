//
//  cperf_backtrace.h
//  跨线程栈回溯的 C 实现。
//
//  ## 为什么是 C 而不是 Swift
//
//  1. 这里的代码要在 signal handler 里被调用，必须 async-signal-safe。
//     Swift 会隐式分配内存（ARC、字符串、数组），在崩溃现场分配内存可能再次崩溃，
//     第一现场随之丢失。
//  2. 挂起目标线程后，该线程持有的任何锁都无法释放——**包括 malloc 的内部锁**。
//     此时若回溯代码自己去 malloc，就会死锁在被挂起线程手里，而且是永久死锁。
//
//  因此本层的所有函数都保证：不分配内存、不加锁、不调用可能阻塞的 API。
//  所有输出缓冲都由调用方提供。
//

#ifndef CPERF_BACKTRACE_H
#define CPERF_BACKTRACE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 单次回溯的最大帧数。超出即截断并置位 `truncated`。
#define CPERF_MAX_FRAMES 128

/// 一次回溯中最多枚举的线程数。
#define CPERF_MAX_THREADS 128

/// 关键寄存器快照。
typedef struct {
    uint64_t pc;   ///< 程序计数器
    uint64_t lr;   ///< 链接寄存器（arm64；x86_64 上恒为 0）
    uint64_t sp;   ///< 栈指针
    uint64_t fp;   ///< 帧指针
} cperf_registers_t;

/// 回溯结果。调用方提供存储，本层不分配内存。
typedef struct {
    uint64_t frames[CPERF_MAX_FRAMES];
    size_t frame_count;
    cperf_registers_t registers;
    /// 是否因达到 `CPERF_MAX_FRAMES` 而截断。
    bool truncated;
} cperf_backtrace_t;

/// 一个已加载的二进制镜像。
typedef struct {
    const char *path;      ///< 指向 dyld 内部字符串，无需释放
    uint64_t load_address;
    uint64_t slide;        ///< ASLR 滑动量
    uint8_t uuid[16];
    bool has_uuid;
} cperf_image_t;

/// 单个地址的符号化结果。
typedef struct {
    const char *image_path;   ///< 指向 dyld 内部字符串，无需释放
    uint64_t image_address;
    const char *symbol_name;  ///< 可能为 NULL（Release 构建下常见）
    uint64_t symbol_address;
} cperf_symbol_t;

#pragma mark - 主线程

/// 登记主线程的 mach 端口。**必须在主线程上调用**，通常在框架 bootstrap 时。
///
/// 为什么要提前登记而不是用时再查：
/// `pthread_main_thread_np()` 是 macOS 专有的，iOS 上没有；
/// 而 `task_threads()` 返回的线程数组顺序**没有任何保证**。
/// 上一版直接取 `threads[0]` 当主线程并对它 `thread_suspend`，
/// 实际可能挂起的是任意一个线程——后果远比拿不到堆栈严重。
///
/// 这里用 `pthread_mach_thread_np(pthread_self())`：它不增加端口引用计数，
/// 不需要配对的 `mach_port_deallocate`，可以安全地长期持有。
void cperf_register_main_thread(void);

/// 主线程的 mach 端口。未登记时返回 MACH_PORT_NULL。
mach_port_t cperf_main_thread_port(void);

/// 目标端口是否是主线程。
bool cperf_is_main_thread_port(mach_port_t thread);

#pragma mark - 回溯

/// 回溯指定线程。
///
/// 目标是当前线程时直接就地回溯，不挂起（挂起自己会永久卡死）。
/// 否则先 `thread_suspend`，读寄存器并沿帧指针链展开，最后 `thread_resume`。
///
/// @return KERN_SUCCESS 表示成功。
kern_return_t cperf_backtrace_thread(mach_port_t thread, cperf_backtrace_t *out);

/// 回溯主线程。未登记主线程时返回 KERN_FAILURE。
kern_return_t cperf_backtrace_main_thread(cperf_backtrace_t *out);

/// 枚举进程内的全部线程。
///
/// 调用方需负责调用 `cperf_free_thread_list` 释放返回的数组。
/// 这是本层唯一会分配资源的函数，因此**不可**在 signal handler 中使用。
kern_return_t cperf_thread_list(thread_act_array_t *threads, mach_msg_type_number_t *count);

/// 释放 `cperf_thread_list` 返回的数组。
void cperf_free_thread_list(thread_act_array_t threads, mach_msg_type_number_t count);

/// 线程名。取不到时写入空串。
void cperf_thread_name(mach_port_t thread, char *buffer, size_t buffer_size);

#pragma mark - 符号化

/// 用 `dladdr` 解析一个地址。
///
/// 注意 `dladdr` **不是** async-signal-safe（内部会加 dyld 锁）。
/// 崩溃现场只应记录裸地址，符号化留到下次启动或服务端做。
bool cperf_symbolicate(uint64_t address, cperf_symbol_t *out);

/// 已加载镜像数量。
uint32_t cperf_image_count(void);

/// 读取第 `index` 个镜像的信息。
///
/// 镜像 UUID + 偏移是服务端符号化的**必要**输入：ASLR 让绝对地址每次运行都不同，
/// 只有这两者才能在 dSYM 里定位到源码。上一版只在文档里写了 atos 脚本，
/// 代码侧从未产出 UUID 和 slide，那份脚本实际无法使用。
bool cperf_image_at_index(uint32_t index, cperf_image_t *out);

#ifdef __cplusplus
}
#endif

#endif /* CPERF_BACKTRACE_H */
