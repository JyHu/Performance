import Foundation

/// 注入给监测器的依赖容器。
///
/// 监测器拿到的一切能力都在这里，**没有单例可用**。
/// 上一版有 10 个单例（其中 2 个的 `shared` 从未被使用），
/// 任何一个监测器都能在任意时刻触碰全局状态，
/// 直接后果是 15 个模块里 14 个无法写单元测试。
public struct PerfMonitorContext: Sendable {
    /// 数据出口。
    public let recorder: PerfRecorder

    /// 采样节拍。监测器**不应**自己创建定时器。
    public let scheduler: any PerfScheduling

    /// 时钟。监测器**不应**直接调用 `Date()` 或 `mach_absolute_time()`。
    public let clock: any PerfClock

    /// 框架诊断日志（不是性能数据）。
    public let log: PerfLog

    /// 栈回溯能力。未链接 `PerfBacktrace` 时为 nil，
    /// 需要它的监测器应降级而非崩溃。
    public let backtrace: (any PerfBacktraceProviding)?

    /// app 生命周期事件源。
    public let lifecycle: any PerfAppLifecycleProviding

    public var sessionID: PerfSessionID { recorder.sessionID }

    public init(
        recorder: PerfRecorder,
        scheduler: any PerfScheduling,
        clock: any PerfClock,
        log: PerfLog,
        backtrace: (any PerfBacktraceProviding)? = nil,
        lifecycle: any PerfAppLifecycleProviding
    ) {
        self.recorder = recorder
        self.scheduler = scheduler
        self.clock = clock
        self.log = log
        self.backtrace = backtrace
        self.lifecycle = lifecycle
    }

    /// 派生一个日志分类指向具体监测器的 context。
    public func scoped(to id: PerfMonitorID) -> PerfMonitorContext {
        PerfMonitorContext(
            recorder: recorder,
            scheduler: scheduler,
            clock: clock,
            log: log.scoped(id.rawValue),
            backtrace: backtrace,
            lifecycle: lifecycle
        )
    }
}
