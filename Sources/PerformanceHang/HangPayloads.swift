import Foundation
import PerformanceCore

/// 主线程无响应的严重程度分级。
///
/// 分级而不是只用一个布尔值：200ms 的顿挫和 8 秒的假死是完全不同的问题，
/// 前者是体验瑕疵，后者会触发系统看门狗直接杀进程。
public enum PerfHangStage: String, Codable, Sendable, CaseIterable {
    /// 单次 RunLoop 迭代超时，用户能感觉到顿挫。
    case hitch
    /// 主线程持续无响应，已达到「应用无响应」的程度。
    case unresponsive
    /// 持续时间长到系统可能介入终止进程。
    case severe
}

/// 主线程无响应事件。
public struct PerfHangEvent: PerfPayload, Equatable {
    public static let kind: PerfKind = "hang.anr"

    public let stage: PerfHangStage
    /// 已经卡了多久（毫秒）。
    public let durationMs: Double
    /// 上报时主线程是否**仍然**卡着。
    ///
    /// 这是本设计的关键优势：卡顿检测发生在后台线程，
    /// 因此能在主线程**还卡着的时候**抓到现场堆栈，而不是等它恢复之后
    /// 才拿到一个已经无关的调用栈。
    public let isOngoing: Bool
    /// 主线程当时的调用栈。抓取失败时为 nil。
    public let mainThreadStack: PerfThreadSnapshot?
    /// 调用栈签名，用于把同一处卡顿的多次上报聚合到一起。
    public let stackSignature: UInt64?

    public init(
        stage: PerfHangStage,
        durationMs: Double,
        isOngoing: Bool,
        mainThreadStack: PerfThreadSnapshot?,
        stackSignature: UInt64?
    ) {
        self.stage = stage
        self.durationMs = durationMs
        self.isOngoing = isOngoing
        self.mainThreadStack = mainThreadStack
        self.stackSignature = stackSignature
    }
}

/// 主线程疑似死锁。
public struct PerfDeadlockEvent: PerfPayload, Equatable {
    public static let kind: PerfKind = "hang.deadlock"

    public let durationMs: Double
    /// 连续多少次采样的寄存器完全没变。
    ///
    /// 这是区分「卡住不动」与「跑得很慢」的判据：
    /// 后者的 PC 会持续变化，前者的不会。
    public let unchangedSampleCount: Int
    public let registers: PerfRegisters
    public let mainThreadStack: PerfThreadSnapshot?
    /// 全部线程的调用栈。
    ///
    /// 死锁必然涉及至少两方：只看主线程只能知道它在等什么锁，
    /// 不知道锁被谁持有。所以这里要带上全景。
    public let allThreadStacks: [PerfThreadSnapshot]?

    public init(
        durationMs: Double,
        unchangedSampleCount: Int,
        registers: PerfRegisters,
        mainThreadStack: PerfThreadSnapshot?,
        allThreadStacks: [PerfThreadSnapshot]?
    ) {
        self.durationMs = durationMs
        self.unchangedSampleCount = unchangedSampleCount
        self.registers = registers
        self.mainThreadStack = mainThreadStack
        self.allThreadStacks = allThreadStacks
    }
}

/// 单次 RunLoop 迭代耗时过长。
public struct PerfHitchEvent: PerfPayload, Equatable {
    public static let kind: PerfKind = "hang.hitch"

    /// 本次迭代从被唤醒到重新进入休眠的耗时（毫秒）。
    public let durationMs: Double
    /// 触发本次迭代的 RunLoop 模式。
    ///
    /// 区分模式很重要：`UITrackingRunLoopMode` 下的卡顿发生在用户
    /// 正在滑动的时候，体感远比空闲时的同等耗时糟糕。
    public let runLoopMode: String?

    public init(durationMs: Double, runLoopMode: String?) {
        self.durationMs = durationMs
        self.runLoopMode = runLoopMode
    }
}

/// RunLoop 各阶段耗时分解。
public struct PerfRunLoopPhaseSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "hang.runloop_phase"

    /// 处理 timer 的耗时（毫秒）。
    public let timersMs: Double
    /// 处理 source 与事件的耗时（毫秒）。
    public let sourcesMs: Double
    /// 本次迭代总耗时（毫秒）。
    public let totalMs: Double

    public init(timersMs: Double, sourcesMs: Double, totalMs: Double) {
        self.timersMs = timersMs
        self.sourcesMs = sourcesMs
        self.totalMs = totalMs
    }
}

/// 主队列排队时延。
public struct PerfQueueLatencySample: PerfPayload, Equatable {
    public static let kind: PerfKind = "hang.queue_latency"

    /// 从投递到主队列，到真正开始执行，中间等了多久（毫秒）。
    ///
    /// 与「主线程卡顿」是两个角度：卡顿看的是单次工作有多长，
    /// 排队时延看的是新任务要等多久才能被处理——
    /// 大量短任务同样会把时延推高，而这在卡顿指标上看不出来。
    public let latencyMs: Double

    public init(latencyMs: Double) {
        self.latencyMs = latencyMs
    }
}
