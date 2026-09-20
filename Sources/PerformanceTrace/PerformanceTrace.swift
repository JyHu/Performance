import Foundation
import PerformanceCore

/// 自定义打点：Span / Signpost / 页面耗时 / 布局耗时 / 业务链路。阶段 4 实现。
///
/// 上一版把这些做成了四套独立 API（`PMMonitor.trace*`、`PMIOTracker`、
/// `PMLayoutRenderTracker`、`PMBusinessTracker`），每一套都自己算了一遍
/// `Double(end - start) / 1_000_000.0`，四份几乎相同的样板代码。
/// 这里统一成一个可嵌套、带属性的 `Span` 模型。
///
/// 命名空间枚举 `PerformanceTrace` 与全局入口 `PerfTrace` 同名冲突，
/// 已并入全局 `PerfTrace`，见 `PerfTraceMonitor.swift`。
