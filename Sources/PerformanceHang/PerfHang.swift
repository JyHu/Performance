import Foundation
import PerformanceCore
import PerformanceBacktrace
import PerformanceSystemKit

/// 主线程健康监测：ANR / 死锁 / RunLoop 卡顿 / 主队列排队延迟。阶段 4 实现。
///
/// 这四件事合在一个 target 里，是因为它们共享同一套底层机制——
/// **一个** watchdog 和**一个** RunLoop observer。
///
/// 上一版把 ANR 和死锁拆成两个模块，各自建队列、各自建定时器、
/// 各自用 semaphore 往主队列投递探针，而且两者默认都开启：
/// 主线程被两路互不知情的 ping 同时打扰，开销翻倍，检测结果还可能互相干扰。
public enum PerfHang {
    public static let monitorID: PerfMonitorID = "hang"

    public enum Kinds {
        /// 主线程无响应超过阈值。
        public static let anr: PerfKind = "hang.anr"
        /// 主线程停在原地不动（连续采样的寄存器签名不变）。
        public static let deadlock: PerfKind = "hang.deadlock"
        /// 单次 RunLoop 循环耗时超阈值。
        public static let hitch: PerfKind = "hang.hitch"
        /// RunLoop 各阶段耗时分解。
        public static let runLoopPhase: PerfKind = "hang.runloop_phase"
        /// 任务从投递到主队列到真正执行之间的排队时延。
        public static let queueLatency: PerfKind = "hang.queue_latency"
    }
}
