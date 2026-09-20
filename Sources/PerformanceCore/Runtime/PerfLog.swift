import Foundation
import os

/// 框架自身的诊断日志。
///
/// 注意这是**框架的**日志，不是采集到的性能数据——性能数据走 `PerfEventSink`。
/// 混淆这两者会让框架的调试信息污染性能数据集。
public struct PerfLog: Sendable {
    public static let subsystem = "com.performance.framework"

    private let logger: Logger
    private let isEnabled: Bool

    public init(category: String, isEnabled: Bool = true) {
        self.logger = Logger(subsystem: PerfLog.subsystem, category: category)
        self.isEnabled = isEnabled
    }

    /// 派生一个子分类的 logger，继承启用状态。
    public func scoped(_ category: String) -> PerfLog {
        PerfLog(category: category, isEnabled: isEnabled)
    }

    /// 消息用 `@autoclosure` 延迟求值：日志关闭时不会付出字符串插值的代价。
    ///
    /// 求值结果先落到局部变量再交给 `Logger`——`Logger` 的字符串插值本身
    /// 接收的是 escaping autoclosure，直接把非 escaping 的 `message()` 传进去无法编译。
    public func debug(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
    }

    public func info(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    public func warning(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.warning("\(text, privacy: .public)")
    }

    /// 错误始终记录，不受 `isEnabled` 影响——框架自身出问题必须可见。
    public func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
    }

    /// 完全静默的 logger，供测试使用。
    public static let disabled = PerfLog(category: "disabled", isEnabled: false)
}
