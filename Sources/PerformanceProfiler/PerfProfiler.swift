import Foundation
import PerformanceCore
import PerformanceBacktrace

/// 热点方法采样。阶段 5 实现。
///
/// 采样必须由**独立线程**挂起目标线程来取栈。
/// 上一版用 `DispatchQueue.main.async { Thread.callStackSymbols }` 采样——
/// 主线程一旦真的忙起来，这个 block 根本排不上队，
/// 于是「热点采样器」只在主线程空闲时采得到样本：想测热点，测到的全是空闲。
public enum PerfProfiler {
    public static let monitorID: PerfMonitorID = "profiler"

    public enum Kinds {
        public static let hotspot: PerfKind = "profiler.hotspot"
    }
}
