import Foundation
import PerformanceCore
import PerformanceSystemKit

/// 启动耗时监测。阶段 4 实现。
public enum PerfLaunch {
    public static let monitorID: PerfMonitorID = "launch"

    public enum Kinds {
        /// 进程创建 → main() 之前，主要是动态库加载与 runtime 初始化。
        public static let preMain: PerfKind = "launch.pre_main"
        /// 冷启动总耗时（进程创建 → 首帧）。
        public static let cold: PerfKind = "launch.cold"
        /// 热启动耗时（回到前台 → 可交互）。
        public static let warm: PerfKind = "launch.warm"
        /// 业务自定义的启动阶段。
        public static let stage: PerfKind = "launch.stage"
    }
}
