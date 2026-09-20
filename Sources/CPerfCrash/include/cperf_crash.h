//
//  cperf_crash.h
//  崩溃捕获。
//
//  ## 崩溃现场的约束比普通代码严苛得多
//
//  - signal handler 里只能调用 **async-signal-safe** 的函数。
//    `malloc`、`printf`、`NSLog`、任何 Objective-C 消息发送都不在此列。
//    Swift 代码更是完全不能用——它会隐式分配内存、做 ARC 操作。
//  - 进程已处于未定义状态，任何二次崩溃都会让第一现场彻底丢失。
//  - 崩溃可能发生在 malloc 持锁的时候；此时再去 malloc 会直接死锁。
//
//  因此这里的策略是：**只写最少的原始字节，不做任何解析**。
//  缓冲区在安装时就预分配好，落盘用 `write(2)` 直写。
//  裸报告要到**下次启动**才被读出来解析成结构化数据——
//  那时进程是健康的，想怎么解析都行。
//
//  上一版只装了 `NSSetUncaughtExceptionHandler`，即只能捕获 Objective-C 异常。
//  而 iOS 上绝大多数崩溃是 `SIGSEGV`（野指针）、`SIGABRT`（断言、未捕获的
//  Swift 错误）、`EXC_BAD_ACCESS`，这些全都拦不到。
//

#ifndef CPERF_CRASH_H
#define CPERF_CRASH_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 裸报告的格式版本，写在文件头。
#define CPERF_CRASH_REPORT_VERSION 1

/// 安装崩溃处理器。
///
/// @param report_path 裸报告的落盘路径。**必须是绝对路径**，
///        且目录需已存在——崩溃现场不能创建目录（那会调用 malloc）。
///        路径会被拷进预分配的缓冲区，调用方无需保持字符串存活。
/// @return 安装成功返回 true。重复安装返回 false。
bool cperf_crash_install(const char *report_path);

/// 卸载崩溃处理器，恢复先前的 handler。
void cperf_crash_uninstall(void);

/// 是否已安装。
bool cperf_crash_is_installed(void);

/// 手动写一份报告。用于自测，不经过真实信号。
bool cperf_crash_write_test_report(void);

#ifdef __cplusplus
}
#endif

#endif /* CPERF_CRASH_H */
