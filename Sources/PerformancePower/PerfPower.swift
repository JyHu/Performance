import Foundation
import PerformanceCore

/// 电量与热状态监测。阶段 5 实现。
///
/// 热状态尤其值得采：设备一旦进入 `.serious`/`.critical`，
/// 系统会主动降频并限制刷新率，此时观测到的卡顿是**被降频导致的**，
/// 与代码问题无关。没有这个维度，性能数据会被大量环境噪声污染。
public enum PerfPower {
    public static let monitorID: PerfMonitorID = "power"

    public enum Kinds {
        public static let battery: PerfKind = "power.battery"
        public static let thermal: PerfKind = "power.thermal"
    }
}
