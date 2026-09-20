import Foundation

/// 一条性能记录：统一的信封 + 类型安全的载荷。
public struct PerfRecord<Payload: PerfPayload>: Sendable {
    public let id: UUID
    /// 墙上时钟，用于人读和跨设备对齐。
    public let timestamp: Date
    /// 单调时钟，用于计算间隔。
    ///
    /// 必须与 `timestamp` 并存：墙上时钟会被 NTP 校正、用户改时间、跨时区切换影响，
    /// 用它算两条记录的间隔可能得到负数；单调时钟不受影响但无法跨进程对齐。
    public let uptimeNanos: UInt64
    public let sessionID: PerfSessionID
    public let severity: PerfSeverity
    /// 产生这条记录的线程。采样类记录通常指被观测的线程，而非采集线程。
    public let thread: PerfThreadRef?
    public let payload: Payload

    public var kind: PerfKind { Payload.kind }

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        uptimeNanos: UInt64,
        sessionID: PerfSessionID,
        severity: PerfSeverity = .info,
        thread: PerfThreadRef? = nil,
        payload: Payload
    ) {
        self.id = id
        self.timestamp = timestamp
        self.uptimeNanos = uptimeNanos
        self.sessionID = sessionID
        self.severity = severity
        self.thread = thread
        self.payload = payload
    }

    /// 擦除载荷类型，以便放进统一的缓冲与管道。
    public func erased() -> PerfAnyRecord {
        PerfAnyRecord(
            id: id,
            timestamp: timestamp,
            uptimeNanos: uptimeNanos,
            sessionID: sessionID,
            severity: severity,
            thread: thread,
            kind: Payload.kind,
            schemaVersion: Payload.schemaVersion,
            payload: payload
        )
    }
}

// MARK: - 类型擦除

/// 载荷类型被擦除的记录，用于在缓冲区和管道里承载异构数据。
///
/// 注意载荷保持为 `any PerfPayload` 的存在式而**不是**提前编码成 `Data`：
/// 编码是有成本的，而采集点可能在主线程 RunLoop 回调里——
/// 编码工作必须推迟到后台的 drain 阶段。
public struct PerfAnyRecord: Sendable {
    public let id: UUID
    public let timestamp: Date
    public let uptimeNanos: UInt64
    public let sessionID: PerfSessionID
    public let severity: PerfSeverity
    public let thread: PerfThreadRef?
    public let kind: PerfKind
    public let schemaVersion: Int
    public let payload: any PerfPayload

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        uptimeNanos: UInt64,
        sessionID: PerfSessionID,
        severity: PerfSeverity,
        thread: PerfThreadRef?,
        kind: PerfKind,
        schemaVersion: Int,
        payload: any PerfPayload
    ) {
        self.id = id
        self.timestamp = timestamp
        self.uptimeNanos = uptimeNanos
        self.sessionID = sessionID
        self.severity = severity
        self.thread = thread
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    /// 还原具体载荷类型。类型不匹配时返回 nil。
    public func payload<P: PerfPayload>(as type: P.Type) -> P? {
        payload as? P
    }
}

// MARK: - JSONL 行编码

extension PerfAnyRecord: Encodable {
    /// 短键名控制落盘体积：性能数据量大且高度重复，
    /// 键名从 `timestamp` 缩到 `ts` 在百万级记录上能省下可观的磁盘。
    enum CodingKeys: String, CodingKey {
        case formatVersion = "v"
        case kind = "k"
        case schemaVersion = "s"
        case id = "id"
        case timestamp = "ts"
        case uptimeNanos = "up"
        case severity = "sev"
        case thread = "th"
        case payload = "p"
    }

    /// 行格式版本，与 payload 的 schemaVersion 相互独立：
    /// 前者描述信封结构，后者描述载荷结构。
    public static let lineFormatVersion = 1

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.lineFormatVersion, forKey: .formatVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
        try container.encode(uptimeNanos, forKey: .uptimeNanos)
        try container.encode(severity, forKey: .severity)
        try container.encodeIfPresent(thread, forKey: .thread)
        try container.encode(PayloadBox(payload), forKey: .payload)
    }

    /// 把存在式 `any PerfPayload` 转发给具体类型的 `encode(to:)`。
    private struct PayloadBox: Encodable {
        let payload: any PerfPayload

        init(_ payload: any PerfPayload) {
            self.payload = payload
        }

        func encode(to encoder: any Encoder) throws {
            try payload.encode(to: encoder)
        }
    }
}

// MARK: - 读取侧

/// 从 JSONL 读出的一条记录，信封已解析、载荷保持原始字节。
///
/// 载荷延迟解码有两个理由：一是查询往往只按信封字段（时间、kind、severity）过滤，
/// 大部分记录根本不需要解码载荷；二是调用方不一定持有产生该载荷的 target
/// （比如只链接了 `PerfRendering` 的进程读到了 `hang.anr` 的记录），
/// 此时信封仍然可读，不会整行失败。
public struct PerfRawRecord: Sendable {
    public let formatVersion: Int
    public let kind: PerfKind
    public let schemaVersion: Int
    public let id: UUID
    public let timestamp: Date
    public let uptimeNanos: UInt64
    public let severity: PerfSeverity
    public let thread: PerfThreadRef?

    /// 原始整行 JSON。载荷解码时在这上面重新走一次 `JSONDecoder`，
    /// 省去维护一套中间 JSON 表示。
    public let lineData: Data

    public init(lineData: Data, envelope: Envelope) {
        self.lineData = lineData
        self.formatVersion = envelope.formatVersion
        self.kind = envelope.kind
        self.schemaVersion = envelope.schemaVersion
        self.id = envelope.id
        self.timestamp = Date(timeIntervalSince1970: envelope.timestamp)
        self.uptimeNanos = envelope.uptimeNanos
        self.severity = envelope.severity
        self.thread = envelope.thread
    }

    /// 解码为具体载荷类型。
    ///
    /// - Throws: `PerfRecordDecodingError.kindMismatch` 当请求的类型与记录的 kind 不符。
    public func decodePayload<P: PerfPayload>(
        as type: P.Type,
        decoder: JSONDecoder = PerfRawRecord.defaultDecoder
    ) throws -> P {
        guard P.kind == kind else {
            throw PerfRecordDecodingError.kindMismatch(expected: P.kind, actual: kind)
        }
        return try decoder.decode(PayloadOnlyLine<P>.self, from: lineData).payload
    }

    /// 信封部分，供 reader 解析。
    public struct Envelope: Decodable, Sendable {
        public let formatVersion: Int
        public let kind: PerfKind
        public let schemaVersion: Int
        public let id: UUID
        public let timestamp: TimeInterval
        public let uptimeNanos: UInt64
        public let severity: PerfSeverity
        public let thread: PerfThreadRef?

        enum CodingKeys: String, CodingKey {
            case formatVersion = "v"
            case kind = "k"
            case schemaVersion = "s"
            case id = "id"
            case timestamp = "ts"
            case uptimeNanos = "up"
            case severity = "sev"
            case thread = "th"
        }
    }

    /// 只取 `p` 字段的视图，用于二次解码载荷。
    private struct PayloadOnlyLine<P: PerfPayload>: Decodable {
        let payload: P

        enum CodingKeys: String, CodingKey {
            case payload = "p"
        }
    }

    public static let defaultDecoder = JSONDecoder()
}

public enum PerfRecordDecodingError: Error, Sendable {
    case kindMismatch(expected: PerfKind, actual: PerfKind)
}
