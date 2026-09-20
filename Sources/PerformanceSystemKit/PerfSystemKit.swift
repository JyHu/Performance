import CPerfBacktrace
import Foundation
import PerformanceCore

/// mach / Darwin 系统原语的**唯一**封装。
///
/// ## 存在的理由是消除重复
///
/// 上一版把「取 CPU 占用和内存」这件事写了三遍，分散在
/// `PMSystemMetricsMonitor`、`PMDiagnosticCollector`、`PMANRReporter` 里，
/// 而且实现还不一致——一个用 `TASK_BASIC_INFO.resident_size`，
/// 另一个用 `TASK_VM_INFO.phys_footprint`。这两者含义不同、数值也对不上，
/// 于是同一时刻的「内存占用」在不同报表里是两个数，谁也不知道该信哪个。
///
/// 三处 `task_threads` + `thread_info` 的循环也几乎逐行相同。
public enum PerfSystemKit {
    public static let moduleVersion = PerfFramework.version

    /// 登记主线程。**必须在主线程调用**，通常在框架 bootstrap 时。
    ///
    /// 转发到 C 层那一份唯一登记，`PerfBacktrace.registerMainThread()`
    /// 也指向同一处。两边调哪个都行，不会出现两份状态。
    public static func registerMainThread() {
        cperf_register_main_thread()
    }

    /// 主线程是否已登记。
    ///
    /// 未登记时「是否主线程」的判断会一律返回 false，
    /// 表现为数据静默变错而非报错，所以需要一个能主动自检的入口。
    public static var isMainThreadRegistered: Bool {
        cperf_main_thread_port() != mach_port_t(MACH_PORT_NULL)
    }
}

/// 一次完整的系统快照。
///
/// 卡顿、ANR、崩溃发生时一次性带上全部环境指标——
/// 事后排查最怕的就是「知道卡了，但不知道当时内存和 CPU 什么样」。
public struct PerfSystemSnapshot: Sendable {
    public let memory: PerfMemoryMetrics
    public let cpuTime: PerfCPUTime?
    public let threadCount: Int
    public let diskIO: PerfDiskIO?
    public let isDebuggerAttached: Bool

    public static func capture() -> PerfSystemSnapshot {
        PerfSystemSnapshot(
            memory: .current(),
            cpuTime: PerfCPUMetrics.processCPUTime(),
            threadCount: PerfCPUMetrics.threadCount(),
            diskIO: PerfDiskMetrics.processIO(),
            isDebuggerAttached: PerfProcessMetrics.isDebuggerAttached()
        )
    }
}
