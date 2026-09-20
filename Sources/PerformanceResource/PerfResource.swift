import Foundation
import PerformanceCore
import PerformanceSystemKit

/// CPU / 内存 / 线程数监测。阶段 4 实现。
public enum PerfResource {
    public static let monitorID: PerfMonitorID = "resource"

    public enum Kinds {
        public static let cpu: PerfKind = "resource.cpu"
        public static let memory: PerfKind = "resource.memory"
        public static let threads: PerfKind = "resource.threads"
    }
}
