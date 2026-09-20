import Foundation

/// 一次 app 运行的标识。
///
/// 所有记录都归属某个 session，排查时可以把「这次崩溃前发生了什么」限定在同一次运行内，
/// 而不用在跨越多次启动的时间线里大海捞针。
public struct PerfSessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 形如 `20260920T103045-A1B2C3`：时间前缀保证目录按字典序即按时间序，
    /// 随机后缀避免同一秒内重启导致的目录冲突。
    public static func generate(date: Date = Date(), randomSuffix: String? = nil) -> PerfSessionID {
        let suffix = randomSuffix ?? String(format: "%06X", UInt32.random(in: 0...0xFFFFFF))
        return PerfSessionID(rawValue: "\(Self.timestampFormatter.string(from: date))-\(suffix)")
    }

    public var description: String { rawValue }

    /// 固定格式 + POSIX locale，避免用户区域设置影响目录名。
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()
}

/// Session 的元信息，落盘为 `manifest.json`。
///
/// 事后排查性能数据时，设备型号、OS 版本、app 版本是判断问题是否环境相关的第一手依据；
/// 把它写在 session 级别而不是每条记录里，避免重复存储。
public struct PerfSessionManifest: Codable, Sendable {
    /// manifest 自身的格式版本，便于后续演进时兼容旧数据。
    public var formatVersion: Int
    public var sessionID: PerfSessionID
    public var startedAt: Date
    /// 正常结束时写入；进程被杀时保持 nil，可据此识别非正常退出。
    public var endedAt: Date?
    public var device: PerfDeviceInfo
    /// 框架自身的版本，用于区分是框架变更还是 app 变更导致的数据差异。
    public var frameworkVersion: String
    /// 本次运行启用了哪些监测器。
    public var enabledMonitors: [String]

    public init(
        formatVersion: Int = PerfSessionManifest.currentFormatVersion,
        sessionID: PerfSessionID,
        startedAt: Date,
        endedAt: Date? = nil,
        device: PerfDeviceInfo,
        frameworkVersion: String = PerfFramework.version,
        enabledMonitors: [String]
    ) {
        self.formatVersion = formatVersion
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.device = device
        self.frameworkVersion = frameworkVersion
        self.enabledMonitors = enabledMonitors
    }

    public static let currentFormatVersion = 1
}

/// 框架自身的版本信息。
public enum PerfFramework {
    public static let version = "0.1.0"
}
