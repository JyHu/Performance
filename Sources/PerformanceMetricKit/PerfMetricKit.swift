import Foundation
import PerformanceCore

/// MetricKit 桥接。阶段 5 实现。
///
/// MetricKit 提供的是**系统视角**的聚合数据（启动耗时、挂起率、磁盘写入量、
/// 电量消耗、崩溃与卡顿诊断），由系统在设备空闲时统计并每日投递一次。
///
/// 它与框架自采数据是互补关系而非替代：
/// MetricKit 精度高、无侵入、无额外开销，但有最长 24 小时延迟，
/// 且拿不到业务上下文；自采数据实时且可关联业务，但要付出运行时开销。
public enum PerfMetricKit {
    public static let monitorID: PerfMonitorID = "metrickit"

    public enum Kinds {
        public static let payload: PerfKind = "metrickit.payload"
        public static let diagnostic: PerfKind = "metrickit.diagnostic"
    }
}
