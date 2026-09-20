import Foundation
import PerformanceCore

/// 网络性能监测：DNS / connect / TLS / TTFB / total / 超时率。阶段 5 实现。
public enum PerfNetwork {
    public static let monitorID: PerfMonitorID = "network"

    public enum Kinds {
        public static let request: PerfKind = "network.request"
        public static let failure: PerfKind = "network.failure"
        /// 滑动窗口内的超时率。
        public static let timeoutRate: PerfKind = "network.timeout_rate"
    }
}
