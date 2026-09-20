import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 设备与进程的静态信息，写入 session 的 `manifest.json`。
///
/// 放在 session 级别而不是每条记录里：这些值在一次运行内不变，
/// 重复存储在百万级记录上是纯粹的浪费。
public struct PerfDeviceInfo: Codable, Sendable, Hashable {
    /// 硬件型号标识，如 `"iPhone15,2"`、`"MacBookPro18,3"`。
    public let model: String
    public let systemName: String
    public let systemVersion: String
    public let appVersion: String?
    public let appBuild: String?
    public let bundleIdentifier: String?
    public let processName: String
    public let processID: Int32
    public let physicalMemoryBytes: UInt64
    public let processorCount: Int
    public let isSimulator: Bool
    /// 运行架构，符号化时需要。
    public let architecture: String

    public init(
        model: String,
        systemName: String,
        systemVersion: String,
        appVersion: String?,
        appBuild: String?,
        bundleIdentifier: String?,
        processName: String,
        processID: Int32,
        physicalMemoryBytes: UInt64,
        processorCount: Int,
        isSimulator: Bool,
        architecture: String
    ) {
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
        self.processID = processID
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processorCount = processorCount
        self.isSimulator = isSimulator
        self.architecture = architecture
    }

    public static func current() -> PerfDeviceInfo {
        let processInfo = ProcessInfo.processInfo
        let bundle = Bundle.main

        return PerfDeviceInfo(
            model: Self.hardwareModel(),
            systemName: Self.systemName,
            systemVersion: Self.systemVersion(processInfo: processInfo),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            bundleIdentifier: bundle.bundleIdentifier,
            processName: processInfo.processName,
            processID: processInfo.processIdentifier,
            physicalMemoryBytes: processInfo.physicalMemory,
            processorCount: processInfo.processorCount,
            isSimulator: Self.isSimulator,
            architecture: Self.architecture
        )
    }

    // MARK: - 平台差异

    private static var systemName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "unknown"
        #endif
    }

    private static func systemVersion(processInfo: ProcessInfo) -> String {
        let version = processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// 硬件型号。
    ///
    /// iOS 真机读 `hw.machine`（给出 `iPhone15,2` 这样的产品标识）；
    /// macOS 读 `hw.model`（`hw.machine` 在 macOS 上只会返回 `arm64`/`x86_64`，没有型号信息）。
    /// 模拟器上两者都只反映宿主机，真正的模拟机型在环境变量里。
    private static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (Simulator)"
        }
        return "Simulator"
        #elseif os(macOS)
        return sysctlString("hw.model") ?? "Mac"
        #else
        return sysctlString("hw.machine") ?? "unknown"
        #endif
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #elseif arch(arm)
        return "arm"
        #elseif arch(i386)
        return "i386"
        #else
        return "unknown"
        #endif
    }

    /// 读取字符串类型的 sysctl 值。
    static func sysctlString(_ name: String) -> String? {
        // 先用 nil 探出所需长度，再按长度取值
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }

        // sysctl 返回的是 C 字符串，截到第一个 NUL 为止
        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<terminator], as: UTF8.self)
    }
}
