import Foundation

/// 一条性能记录的**类型安全**载荷。
///
/// 每个采集 target 定义自己的具体 payload 类型，字段是强类型的：
///
/// ```swift
/// public struct CPUSample: PerfPayload {
///     public static let kind: PerfKind = "resource.cpu"
///     public let processPercent: Double
///     public let mainThreadPercent: Double
/// }
/// ```
///
/// 这取代了上一版的 `details: [String: String]?` 万能袋。那个设计把所有异构数据
/// 压成字符串字典，写侧 `String(format:)`、读侧 `Double(str)`，类型信息全丢——
/// 直接导致三处写入 key 与读取 key 对不上（`"cpu_percent"` vs `"cpuUsage"`），
/// 相关的严重度判定成了永不生效的死代码，而编译器完全无法发现。
public protocol PerfPayload: Codable, Sendable {
    /// 类型标识，决定落盘到哪个分片文件、查询时如何过滤。
    static var kind: PerfKind { get }

    /// 载荷结构的版本号。字段增删时递增，读取侧据此做兼容处理。
    static var schemaVersion: Int { get }
}

extension PerfPayload {
    public static var schemaVersion: Int { 1 }

    public var kind: PerfKind { Self.kind }
    public var schemaVersion: Int { Self.schemaVersion }
}

// MARK: - 框架自身的元指标

/// 因缓冲区满而丢弃的记录数。
///
/// 采集侧的环形缓冲是有界的——满了只能丢。丢弃如果不上报，
/// 数据缺口就会被误读成「这段时间没问题」，那比没有数据更危险。
public struct PerfDroppedRecords: PerfPayload {
    public static let kind: PerfKind = .coreDropped

    /// 本次统计窗口内丢弃的条数。
    public let count: UInt64
    /// 进程启动以来累计丢弃的条数。
    public let cumulative: UInt64

    public init(count: UInt64, cumulative: UInt64) {
        self.count = count
        self.cumulative = cumulative
    }
}
