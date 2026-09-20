import Foundation

/// 时长。
///
/// 不用标准库 `Duration` 是因为它要求 iOS 16 / macOS 13，而本框架最低支持 iOS 15 / macOS 12。
/// 内部统一以纳秒表示，避免浮点累积误差。
public struct PerfDuration: Hashable, Sendable, Codable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func nanoseconds(_ value: UInt64) -> PerfDuration {
        PerfDuration(nanoseconds: value)
    }

    public static func microseconds(_ value: Double) -> PerfDuration {
        PerfDuration(nanoseconds: UInt64(max(0, value * 1_000)))
    }

    public static func milliseconds(_ value: Double) -> PerfDuration {
        PerfDuration(nanoseconds: UInt64(max(0, value * 1_000_000)))
    }

    public static func seconds(_ value: Double) -> PerfDuration {
        PerfDuration(nanoseconds: UInt64(max(0, value * 1_000_000_000)))
    }

    public static func minutes(_ value: Double) -> PerfDuration {
        .seconds(value * 60)
    }

    public static func hours(_ value: Double) -> PerfDuration {
        .seconds(value * 3_600)
    }

    public static func days(_ value: Double) -> PerfDuration {
        .seconds(value * 86_400)
    }

    public static let zero = PerfDuration(nanoseconds: 0)

    public var milliseconds: Double {
        Double(nanoseconds) / 1_000_000
    }

    public var seconds: Double {
        Double(nanoseconds) / 1_000_000_000
    }

    public var timeInterval: TimeInterval {
        seconds
    }
}

extension PerfDuration: Comparable {
    public static func < (lhs: PerfDuration, rhs: PerfDuration) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

extension PerfDuration {
    public static func + (lhs: PerfDuration, rhs: PerfDuration) -> PerfDuration {
        PerfDuration(nanoseconds: lhs.nanoseconds &+ rhs.nanoseconds)
    }

    /// 饱和减法，不会下溢。
    public static func - (lhs: PerfDuration, rhs: PerfDuration) -> PerfDuration {
        PerfDuration(nanoseconds: lhs.nanoseconds > rhs.nanoseconds ? lhs.nanoseconds - rhs.nanoseconds : 0)
    }

    public static func * (lhs: PerfDuration, rhs: Double) -> PerfDuration {
        PerfDuration(nanoseconds: UInt64(max(0, Double(lhs.nanoseconds) * rhs)))
    }
}

extension PerfDuration: CustomStringConvertible {
    public var description: String {
        if nanoseconds < 1_000 {
            return "\(nanoseconds)ns"
        } else if nanoseconds < 1_000_000 {
            return String(format: "%.2fµs", Double(nanoseconds) / 1_000)
        } else if nanoseconds < 1_000_000_000 {
            return String(format: "%.2fms", milliseconds)
        } else {
            return String(format: "%.3fs", seconds)
        }
    }
}

/// 字节数，用于磁盘配额、分片大小等。
public struct PerfByteCount: Hashable, Sendable, Codable, Comparable {
    public let bytes: UInt64

    public init(bytes: UInt64) {
        self.bytes = bytes
    }

    public static func bytes(_ value: UInt64) -> PerfByteCount { PerfByteCount(bytes: value) }
    public static func kilobytes(_ value: Double) -> PerfByteCount { PerfByteCount(bytes: UInt64(max(0, value * 1_024))) }
    public static func megabytes(_ value: Double) -> PerfByteCount { PerfByteCount(bytes: UInt64(max(0, value * 1_048_576))) }
    public static func gigabytes(_ value: Double) -> PerfByteCount { PerfByteCount(bytes: UInt64(max(0, value * 1_073_741_824))) }

    public static let zero = PerfByteCount(bytes: 0)

    public var megabytes: Double { Double(bytes) / 1_048_576 }

    public static func < (lhs: PerfByteCount, rhs: PerfByteCount) -> Bool {
        lhs.bytes < rhs.bytes
    }
}

extension PerfByteCount: CustomStringConvertible {
    public var description: String {
        if bytes < 1_024 {
            return "\(bytes)B"
        } else if bytes < 1_048_576 {
            return String(format: "%.1fKB", Double(bytes) / 1_024)
        } else if bytes < 1_073_741_824 {
            return String(format: "%.1fMB", megabytes)
        } else {
            return String(format: "%.2fGB", Double(bytes) / 1_073_741_824)
        }
    }
}
