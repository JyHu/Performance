import Foundation

/// 记录的严重度。
///
/// 全框架**只有这一套**分级。上一版同时存在 `PMIssueSeverity{none,low,medium,high,critical}`
/// 和 `PMANRMetrics.Severity{minor,moderate,severe,critical}` 两套互不相通的体系，
/// 导致 ANR 数据和其他数据无法统一排序与过滤。
public enum PerfSeverity: String, Codable, Sendable, CaseIterable {
    /// 仅调试期关注，生产环境通常过滤掉。
    case debug
    /// 常规采样值，无异常。
    case info
    /// 超过警戒阈值，值得关注但不影响可用性。
    case warning
    /// 明确的性能问题，用户可感知。
    case error
    /// 严重问题，如 ANR、死锁、崩溃。
    case critical

    /// 用于比较与阈值过滤的数值等级。
    public var level: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        case .critical: 4
        }
    }
}

extension PerfSeverity: Comparable {
    public static func < (lhs: PerfSeverity, rhs: PerfSeverity) -> Bool {
        lhs.level < rhs.level
    }
}
