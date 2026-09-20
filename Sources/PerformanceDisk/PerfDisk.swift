import Foundation
import PerformanceCore
import PerformanceSystemKit

/// 磁盘空间 / I/O 耗时 / 主线程同步 I/O 监测。阶段 5 实现。
public enum PerfDisk {
    public static let monitorID: PerfMonitorID = "disk"

    public enum Kinds {
        public static let space: PerfKind = "disk.space"
        public static let throughput: PerfKind = "disk.throughput"
        /// 主线程上的同步 I/O——最常见也最容易被忽略的卡顿来源之一。
        public static let mainThreadIO: PerfKind = "disk.main_thread_io"
    }
}
