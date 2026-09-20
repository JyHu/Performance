import Foundation

/// 监测器标识，例如 `"hang"`、`"resource"`。
public struct PerfMonitorID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension PerfMonitorID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension PerfMonitorID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// 监测器支持的平台。
public struct PerfPlatformSupport: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let iOS = PerfPlatformSupport(rawValue: 1 << 0)
    public static let macOS = PerfPlatformSupport(rawValue: 1 << 1)

    public static let all: PerfPlatformSupport = [.iOS, .macOS]

    /// 当前运行平台。
    public static var current: PerfPlatformSupport {
        #if os(iOS)
        return .iOS
        #elseif os(macOS)
        return .macOS
        #else
        return []
        #endif
    }

    /// 是否可在当前平台运行。
    ///
    /// 有了这个判断，编排层可以在启动时**跳过**不支持的监测器并记一条日志，
    /// 而不是让它在运行时静默失效。上一版全仓只有 3 处 `#if canImport(AppKit)`、
    /// 零处 `#if os(iOS)`，平台不兼容表现为编译失败或运行时空转，无从察觉。
    public var isAvailableOnCurrentPlatform: Bool {
        !intersection(.current).isEmpty
    }
}

/// 监测器的静态元信息。
public struct PerfMonitorDescriptor: Sendable, Hashable {
    public let id: PerfMonitorID
    public let displayName: String
    /// 该监测器会产出哪些类型的记录。
    ///
    /// 显式声明的价值：查询时可以反查「谁产生了这类数据」，
    /// 也能在启动时校验是否有两个监测器抢占同一个 kind。
    public let kinds: Set<PerfKind>
    public let platforms: PerfPlatformSupport

    public init(
        id: PerfMonitorID,
        displayName: String,
        kinds: Set<PerfKind>,
        platforms: PerfPlatformSupport = .all
    ) {
        self.id = id
        self.displayName = displayName
        self.kinds = kinds
        self.platforms = platforms
    }
}
