import Foundation

/// 一批待导出的记录。
public struct PerfRecordBatch: Sendable {
    public let sessionID: PerfSessionID
    public let records: [PerfAnyRecord]

    public init(sessionID: PerfSessionID, records: [PerfAnyRecord]) {
        self.sessionID = sessionID
        self.records = records
    }

    public var isEmpty: Bool { records.isEmpty }
}

/// 把性能数据送出框架的抽象。
///
/// ## 框架为什么不内置 HTTP 上报
///
/// 上报涉及的每一件事都是业务决策：打到哪个 endpoint、用什么鉴权、
/// 采样率多少、失败重试几次、是否只在 Wi-Fi 下传、数据合不合规。
/// 框架替业务方做这些决定，结果就是上一版那样——
/// 默认配置里硬编码了一个明文 HTTP 的内网 IP，
/// 上传失败的文件永远留在磁盘上、每 30 秒重传一次，直到把磁盘塞满。
///
/// 所以这里只定义契约。框架保证**零网络依赖**，
/// 业务方实现这个协议并注入，完全掌控上报行为。
public protocol PerfExporter: Sendable {
    /// 用于日志和去重，例如 `"company.telemetry"`。
    var identifier: String { get }

    /// 导出一批记录。
    ///
    /// 抛错表示本批导出失败。编排层会记录日志，但**不会**自动重试——
    /// 重试策略（次数、退避、持久化队列）属于实现者的职责。
    func export(_ batch: PerfRecordBatch) async throws
}

/// 输出到系统日志的导出器，调试用。
public struct PerfConsoleExporter: PerfExporter {
    public let identifier = "core.console"

    private let log: PerfLog
    private let minimumSeverity: PerfSeverity

    public init(minimumSeverity: PerfSeverity = .warning, log: PerfLog = PerfLog(category: "console-exporter")) {
        self.minimumSeverity = minimumSeverity
        self.log = log
    }

    public func export(_ batch: PerfRecordBatch) async throws {
        for record in batch.records where record.severity >= minimumSeverity {
            log.info("[\(record.severity.rawValue)] \(record.kind) @ \(record.timestamp) thread=\(record.thread?.description ?? "-")")
        }
    }
}

/// 把记录转交给一个闭包的导出器，供测试和快速接入使用。
public struct PerfClosureExporter: PerfExporter {
    public let identifier: String
    private let handler: @Sendable (PerfRecordBatch) async throws -> Void

    public init(
        identifier: String = "core.closure",
        handler: @escaping @Sendable (PerfRecordBatch) async throws -> Void
    ) {
        self.identifier = identifier
        self.handler = handler
    }

    public func export(_ batch: PerfRecordBatch) async throws {
        try await handler(batch)
    }
}
