//
//  cperf_system.h
//  进程级资源指标的采集，以及跨平台可用性差异的收敛点。
//
//  ## 为什么需要这一层
//
//  1. **可用性差异**：`proc_pid_rusage` 声明在 `<libproc.h>` 里，
//     而 iOS SDK 根本没有这个头文件——`sys/resource.h` 里只剩一句
//     「Flavors for proc_pid_rusage()」的注释。在 iOS 上调用它意味着
//     自己声明符号，也就是使用私有 API，上架审核有风险。
//     所以磁盘 I/O 字节数在 iOS 上**取不到**，这里如实返回「无此数据」，
//     而不是编一个数出来。
//
//  2. **结构体布局隔离**：`rusage_info_v*` 随系统版本增长过字段，
//     Swift 侧直接映射会跟着变。
//
//  凡是两端都能拿到的指标（CPU 时间、缺页、上下文切换、唤醒次数），
//  一律走公开的 `task_info` 族，两个平台走同一条代码路径。
//

#ifndef CPERF_SYSTEM_H
#define CPERF_SYSTEM_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 进程资源使用量。
typedef struct {
    /// 进程累计用户态 CPU 时间（纳秒）。来自 TASK_ABSOLUTETIME_INFO。
    uint64_t user_time_nanos;
    /// 进程累计内核态 CPU 时间（纳秒）。
    uint64_t system_time_nanos;
    bool has_cpu_time;

    /// 缺页总次数。
    uint64_t faults;
    /// 需要从磁盘换入的缺页次数。激增往往先于内存告警出现。
    uint64_t pageins;
    /// 上下文切换次数。异常增长意味着线程在互相抢占，是线程过多或锁竞争的信号。
    uint64_t context_switches;
    bool has_events;

    /// 内核唤醒次数，与耗电直接相关。
    uint64_t interrupt_wakeups;
    bool has_wakeups;

    /// 累计磁盘读写字节数。
    ///
    /// **仅 macOS 可用**。iOS 上没有公开 API 能拿到，
    /// 此时 `has_disk_io` 为 false，该平台应改用 MetricKit 的磁盘指标。
    uint64_t disk_bytes_read;
    uint64_t disk_bytes_written;
    bool has_disk_io;
} cperf_rusage_t;

/// 读取当前进程的资源使用量。
///
/// 各字段是否有效由对应的 `has_*` 标志决定——
/// 部分指标在某些平台上不可得，返回 0 与「真的是 0」无法区分。
bool cperf_process_rusage(cperf_rusage_t *out);

#ifdef __cplusplus
}
#endif

#endif /* CPERF_SYSTEM_H */
