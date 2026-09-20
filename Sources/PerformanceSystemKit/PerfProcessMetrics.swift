import Darwin
import Foundation
import PerformanceCore

/// 进程级信息。
public enum PerfProcessMetrics {
    /// 进程创建时间。
    ///
    /// 这是**冷启动耗时的真正起点**：从进程被内核创建，到首帧渲染完成。
    /// 上一版用 `ProcessInfo.systemUptime` 当起点，那是设备开机以来的时长，
    /// 与本次进程何时启动毫无关系——算出来的「启动耗时」实际是设备运行时长。
    public static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }

        let started = info.kp_proc.p_starttime
        return Date(
            timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        )
    }

    /// 进程已运行时长。
    public static func uptime(now: Date = Date()) -> PerfDuration? {
        guard let start = processStartDate() else { return nil }
        return .seconds(max(0, now.timeIntervalSince(start)))
    }

    /// 内核层面的活动计数。两个平台都可用。
    public struct KernelActivity: Sendable, Hashable {
        /// 缺页总次数。
        public let faults: UInt64
        /// 需要从磁盘换入的缺页次数。激增往往先于内存告警出现。
        public let pageins: UInt64
        /// 上下文切换次数。异常增长意味着线程互相抢占，是线程过多或锁竞争的信号。
        public let contextSwitches: UInt64
        /// 内核唤醒次数，与耗电直接相关。
        public let interruptWakeups: UInt64
    }

    /// 读取内核活动计数。同样是累计值，由调用方做差分。
    public static func kernelActivity() -> KernelActivity? {
        guard let usage = PerfCPUMetrics.resourceUsage(), usage.has_events else { return nil }
        return KernelActivity(
            faults: usage.faults,
            pageins: usage.pageins,
            contextSwitches: usage.context_switches,
            interruptWakeups: usage.has_wakeups ? usage.interrupt_wakeups : 0
        )
    }

    /// 本进程是否正被调试器附加。
    ///
    /// 调试器会显著改变时序——断点、单步、符号加载都会造成假卡顿。
    /// 带上这个标记，分析时才能把调试会话期间的数据排除掉，
    /// 否则开发期采到的一堆「严重卡顿」会污染整个数据集。
    public static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
