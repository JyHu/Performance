import Foundation

/// 性能记录的类型标识，采用命名空间化的点分字符串，例如 `"hang.anr"`、`"resource.cpu"`。
///
/// 第一段是**大类**（group），持久化时按大类分片到不同文件，
/// 使得按类型查询可以直接跳过无关文件，弥补 JSONL 没有索引的短板。
public struct PerfKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// 大类，用于分片文件命名。`"hang.anr"` → `"hang"`。
    public var group: String {
        if let dot = rawValue.firstIndex(of: ".") {
            return String(rawValue[rawValue.startIndex..<dot])
        }
        return rawValue
    }

    /// 大类之后的部分。`"hang.anr"` → `"anr"`；无点号时为空串。
    public var leaf: String {
        if let dot = rawValue.firstIndex(of: ".") {
            return String(rawValue[rawValue.index(after: dot)...])
        }
        return ""
    }
}

extension PerfKind: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension PerfKind: CustomStringConvertible {
    public var description: String { rawValue }
}

extension PerfKind {
    /// 框架自身的元指标：因缓冲区满而丢弃的记录数。
    ///
    /// 监控不能是黑盒——丢弃本身也要可观测，否则数据缺口会被误读成「没有问题」。
    public static let coreDropped: PerfKind = "core.dropped"
}
