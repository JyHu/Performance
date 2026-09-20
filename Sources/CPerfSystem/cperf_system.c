//
//  cperf_system.c
//

#include "include/cperf_system.h"

#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <TargetConditionals.h>

#if TARGET_OS_OSX
#include <libproc.h>
#endif

/// mach 绝对时间单位 → 纳秒。
///
/// Apple Silicon 上计数器是 24MHz，timebase 为 125/3，直接把 tick 当纳秒会差 40 倍。
/// 用 128 位中间值做乘除，避免长时间运行后 `ticks * numer` 溢出 64 位。
static uint64_t cperf_ticks_to_nanos(uint64_t ticks) {
    static mach_timebase_info_data_t timebase = { 0, 0 };
    if (timebase.denom == 0) {
        if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) {
            return ticks;
        }
    }
    if (timebase.numer == timebase.denom) {
        return ticks;
    }
    return (uint64_t)(((__uint128_t)ticks * timebase.numer) / timebase.denom);
}

/// 进程累计 CPU 时间。
///
/// 用 TASK_ABSOLUTETIME_INFO 而不是 TASK_BASIC_INFO：后者的
/// `user_time`/`system_time` 只累计**已终止**线程的时间，
/// 要得到进程总量还得再遍历全部活动线程逐个相加。
/// 上一版就是这么做的，既慢又会在线程增删的瞬间算漏。
static bool cperf_read_cpu_time(cperf_rusage_t *out) {
    task_absolutetime_info_data_t info;
    mach_msg_type_number_t count = TASK_ABSOLUTETIME_INFO_COUNT;

    kern_return_t result = task_info(
        mach_task_self(),
        TASK_ABSOLUTETIME_INFO,
        (task_info_t)&info,
        &count
    );
    if (result != KERN_SUCCESS) {
        return false;
    }

    out->user_time_nanos = cperf_ticks_to_nanos(info.total_user);
    out->system_time_nanos = cperf_ticks_to_nanos(info.total_system);
    return true;
}

static bool cperf_read_events(cperf_rusage_t *out) {
    task_events_info_data_t info;
    mach_msg_type_number_t count = TASK_EVENTS_INFO_COUNT;

    kern_return_t result = task_info(
        mach_task_self(),
        TASK_EVENTS_INFO,
        (task_info_t)&info,
        &count
    );
    if (result != KERN_SUCCESS) {
        return false;
    }

    out->faults = (uint64_t)info.faults;
    out->pageins = (uint64_t)info.pageins;
    out->context_switches = (uint64_t)info.csw;
    return true;
}

static bool cperf_read_wakeups(cperf_rusage_t *out) {
    task_power_info_data_t info;
    mach_msg_type_number_t count = TASK_POWER_INFO_COUNT;

    kern_return_t result = task_info(
        mach_task_self(),
        TASK_POWER_INFO,
        (task_info_t)&info,
        &count
    );
    if (result != KERN_SUCCESS) {
        return false;
    }

    out->interrupt_wakeups = info.task_interrupt_wakeups;
    return true;
}

#if TARGET_OS_OSX
static bool cperf_read_disk_io(cperf_rusage_t *out) {
    // proc_pid_rusage 的第三个参数是 `void *`，但内核会把**整个结构体**
    // 拷进它指向的位置。必须先备好完整存储——传一个裸指针变量的地址
    // 会让内核写爆那 8 字节，造成栈破坏。
    struct rusage_info_v4 info;
    memset(&info, 0, sizeof(info));

    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) {
        return false;
    }

    out->disk_bytes_read = info.ri_diskio_bytesread;
    out->disk_bytes_written = info.ri_diskio_byteswritten;
    return true;
}
#endif

bool cperf_process_rusage(cperf_rusage_t *out) {
    if (out == NULL) {
        return false;
    }
    memset(out, 0, sizeof(*out));

    out->has_cpu_time = cperf_read_cpu_time(out);
    out->has_events = cperf_read_events(out);
    out->has_wakeups = cperf_read_wakeups(out);

#if TARGET_OS_OSX
    out->has_disk_io = cperf_read_disk_io(out);
#else
    // iOS 没有公开 API 能拿到进程磁盘 I/O 字节数。
    // 如实标记为不可用，由上层改走 MetricKit——
    // 返回 0 会被误读成「完全没有磁盘活动」。
    out->has_disk_io = false;
#endif

    return out->has_cpu_time || out->has_events || out->has_wakeups || out->has_disk_io;
}
