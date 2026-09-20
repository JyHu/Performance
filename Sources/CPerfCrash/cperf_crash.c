//
//  cperf_crash.c
//

#include "include/cperf_crash.h"
#include "../CPerfBacktrace/include/cperf_backtrace.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#pragma mark - 状态

/// 要接管的信号。
///
/// SIGABRT 覆盖了断言失败与未捕获的 Swift 错误；
/// SIGSEGV / SIGBUS 覆盖野指针与非法内存访问；
/// SIGTRAP 是 Swift 运行时在检测到致命错误（数组越界、强解包 nil）时触发的。
static const int kCrashSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
static const size_t kCrashSignalCount = sizeof(kCrashSignals) / sizeof(kCrashSignals[0]);

static struct sigaction g_previous_actions[sizeof(kCrashSignals) / sizeof(kCrashSignals[0])];
static volatile bool g_installed = false;

/// 报告路径。在安装时拷进这块固定缓冲——
/// handler 里不能访问可能已被释放的调用方字符串。
static char g_report_path[1024];

/// 备用信号栈。
///
/// 栈溢出导致的 SIGSEGV 里，当前线程的栈已经没有空间再跑 handler 了。
/// 不给备用栈的话，handler 自己会立刻二次崩溃，第一现场彻底丢失。
static char g_signal_stack[SIGSTKSZ * 4];

/// 防止重入：handler 自己崩了不能再进一次。
static volatile sig_atomic_t g_handling = 0;

#pragma mark - async-signal-safe 的写入原语

/// 循环写直到写完。`write` 是 async-signal-safe 的。
static void safe_write(int fd, const void *buffer, size_t length) {
    const char *cursor = (const char *)buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written <= 0) {
            if (errno == EINTR) continue;
            return;
        }
        cursor += written;
        remaining -= (size_t)written;
    }
}

static void safe_write_string(int fd, const char *text) {
    safe_write(fd, text, strlen(text));
}

/// 手写的无符号整数转十进制。
///
/// 不能用 `snprintf`——它不是 async-signal-safe 的，
/// 内部可能加锁、可能分配内存。
static void safe_write_uint(int fd, uint64_t value) {
    char buffer[24];
    size_t index = sizeof(buffer);
    if (value == 0) {
        safe_write_string(fd, "0");
        return;
    }
    while (value > 0 && index > 0) {
        buffer[--index] = (char)('0' + (value % 10));
        value /= 10;
    }
    safe_write(fd, buffer + index, sizeof(buffer) - index);
}

/// 手写的无符号整数转十六进制。
static void safe_write_hex(int fd, uint64_t value) {
    static const char digits[] = "0123456789abcdef";
    char buffer[18];
    buffer[0] = '0';
    buffer[1] = 'x';
    size_t index = sizeof(buffer);
    if (value == 0) {
        safe_write_string(fd, "0x0");
        return;
    }
    while (value > 0 && index > 2) {
        buffer[--index] = digits[value & 0xF];
        value >>= 4;
    }
    safe_write(fd, "0x", 2);
    safe_write(fd, buffer + index, sizeof(buffer) - index);
}

#pragma mark - 报告写入

/// 写一份裸报告。
///
/// 格式是极简的行式文本，不是 JSON——JSON 编码要做转义和缓冲管理，
/// 在崩溃现场不值得冒这个险。解析留到下次启动时做。
static void write_report(int fd, int signal_number, const cperf_backtrace_t *backtrace) {
    safe_write_string(fd, "cperf-crash-report v");
    safe_write_uint(fd, CPERF_CRASH_REPORT_VERSION);
    safe_write_string(fd, "\nsignal ");
    safe_write_uint(fd, (uint64_t)signal_number);

    safe_write_string(fd, "\ntime ");
    // time() 是 async-signal-safe 的
    safe_write_uint(fd, (uint64_t)time(NULL));

    safe_write_string(fd, "\nthread ");
    safe_write_uint(fd, (uint64_t)pthread_mach_thread_np(pthread_self()));
    safe_write_string(fd,
        cperf_is_main_thread_port(pthread_mach_thread_np(pthread_self()))
            ? " main\n"
            : " background\n");

    if (backtrace != NULL) {
        safe_write_string(fd, "registers ");
        safe_write_hex(fd, backtrace->registers.pc);
        safe_write_string(fd, " ");
        safe_write_hex(fd, backtrace->registers.lr);
        safe_write_string(fd, " ");
        safe_write_hex(fd, backtrace->registers.sp);
        safe_write_string(fd, " ");
        safe_write_hex(fd, backtrace->registers.fp);
        safe_write_string(fd, "\nframes ");
        safe_write_uint(fd, (uint64_t)backtrace->frame_count);
        safe_write_string(fd, "\n");

        for (size_t i = 0; i < backtrace->frame_count; i++) {
            safe_write_hex(fd, backtrace->frames[i]);
            safe_write_string(fd, "\n");
        }
    }

    // 镜像清单：没有它，上面那些地址在服务端无法还原成符号。
    // _dyld_* 系列严格说不是 async-signal-safe，但崩溃时 dyld 锁被持有的
    // 概率很低，而缺了镜像清单整份报告就失去大半价值——这是个明确的取舍。
    safe_write_string(fd, "images\n");
    uint32_t image_count = cperf_image_count();
    for (uint32_t i = 0; i < image_count; i++) {
        cperf_image_t image;
        if (!cperf_image_at_index(i, &image)) continue;

        safe_write_hex(fd, image.load_address);
        safe_write_string(fd, " ");
        safe_write_hex(fd, image.slide);
        safe_write_string(fd, " ");

        if (image.has_uuid) {
            static const char digits[] = "0123456789ABCDEF";
            char uuid_text[32];
            for (int b = 0; b < 16; b++) {
                uuid_text[b * 2] = digits[(image.uuid[b] >> 4) & 0xF];
                uuid_text[b * 2 + 1] = digits[image.uuid[b] & 0xF];
            }
            safe_write(fd, uuid_text, sizeof(uuid_text));
        } else {
            safe_write_string(fd, "-");
        }

        safe_write_string(fd, " ");
        safe_write_string(fd, image.path ? image.path : "-");
        safe_write_string(fd, "\n");
    }

    safe_write_string(fd, "end\n");
}

#pragma mark - signal handler

static void crash_handler(int signal_number, siginfo_t *info, void *context) {
    (void)info;
    (void)context;

    // handler 自己崩了不能再进来一次
    if (g_handling) {
        _exit(1);
    }
    g_handling = 1;

    // O_EXCL：已经有报告就不覆盖。多个线程同时崩溃时，
    // 保住第一份比拿到最后一份更有价值。
    int fd = open(g_report_path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
    if (fd >= 0) {
        cperf_backtrace_t backtrace;
        kern_return_t result = cperf_backtrace_thread(
            pthread_mach_thread_np(pthread_self()),
            &backtrace
        );
        write_report(fd, signal_number, result == KERN_SUCCESS ? &backtrace : NULL);
        // fsync 保证报告真的落到磁盘上：下一步就要把进程还给系统默认
        // handler 去终止，缓冲区里的内容会随进程一起消失。
        fsync(fd);
        close(fd);
    }

    // 恢复默认处理并重新抛出，让系统按正常流程生成它自己的崩溃日志。
    // 不这么做的话，系统的崩溃报告和 MetricKit 的 MXCrashDiagnostic 都会丢失。
    for (size_t i = 0; i < kCrashSignalCount; i++) {
        sigaction(kCrashSignals[i], &g_previous_actions[i], NULL);
    }
    raise(signal_number);
}

#pragma mark - 安装

bool cperf_crash_install(const char *report_path) {
    if (g_installed || report_path == NULL) {
        return false;
    }
    size_t length = strlen(report_path);
    if (length == 0 || length >= sizeof(g_report_path)) {
        return false;
    }
    memcpy(g_report_path, report_path, length + 1);

    // 备用栈：栈溢出导致的 SIGSEGV 里，当前栈已经没空间跑 handler 了
    stack_t signal_stack;
    signal_stack.ss_sp = g_signal_stack;
    signal_stack.ss_size = sizeof(g_signal_stack);
    signal_stack.ss_flags = 0;
    if (sigaltstack(&signal_stack, NULL) != 0) {
        return false;
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = crash_handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);

    for (size_t i = 0; i < kCrashSignalCount; i++) {
        if (sigaction(kCrashSignals[i], &action, &g_previous_actions[i]) != 0) {
            // 部分安装失败：回滚已装的，避免留下半套处理器
            for (size_t j = 0; j < i; j++) {
                sigaction(kCrashSignals[j], &g_previous_actions[j], NULL);
            }
            return false;
        }
    }

    g_installed = true;
    return true;
}

void cperf_crash_uninstall(void) {
    if (!g_installed) {
        return;
    }
    for (size_t i = 0; i < kCrashSignalCount; i++) {
        sigaction(kCrashSignals[i], &g_previous_actions[i], NULL);
    }
    g_installed = false;
}

bool cperf_crash_is_installed(void) {
    return g_installed;
}

bool cperf_crash_write_test_report(void) {
    if (!g_installed) {
        return false;
    }
    int fd = open(g_report_path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR);
    if (fd < 0) {
        return false;
    }

    cperf_backtrace_t backtrace;
    kern_return_t result = cperf_backtrace_thread(
        pthread_mach_thread_np(pthread_self()),
        &backtrace
    );
    write_report(fd, 0, result == KERN_SUCCESS ? &backtrace : NULL);
    close(fd);
    return true;
}
