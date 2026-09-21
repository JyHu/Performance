import Foundation
import PerformanceCore

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
import IOKit.ps
#endif

// MARK: - 载荷

/// 设备热状态。
public struct PerfThermalSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "power.thermal"

    public let state: State
    /// 是否处于低电量模式。
    ///
    /// 低电量模式下系统会主动降频、限制后台活动和刷新率，
    /// 此时观测到的「性能下降」是系统行为，不是代码问题。
    public let isLowPowerModeEnabled: Bool

    public enum State: String, Codable, Sendable, CaseIterable {
        case nominal, fair, serious, critical, unknown

        /// 系统是否已经在为控温而降低性能。
        ///
        /// 到 `serious` 系统就开始降频并限制刷新率了。没有这个维度，
        /// 因降频导致的卡顿会被误判成代码退化，性能数据被环境噪声污染。
        public var isThrottling: Bool {
            self == .serious || self == .critical
        }
    }

    public init(state: State, isLowPowerModeEnabled: Bool) {
        self.state = state
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}

/// 电量采样。
public struct PerfBatterySample: PerfPayload, Equatable {
    public static let kind: PerfKind = "power.battery"

    /// 电量百分比（0~100）。取不到时为 nil。
    public let levelPercent: Double?
    public let isCharging: Bool?
    /// 相对上次采样的电量变化（百分点）。负值表示耗电。
    public let deltaSinceLastSample: Double?
    public let windowMs: Double

    public init(
        levelPercent: Double?,
        isCharging: Bool?,
        deltaSinceLastSample: Double?,
        windowMs: Double
    ) {
        self.levelPercent = levelPercent
        self.isCharging = isCharging
        self.deltaSinceLastSample = deltaSinceLastSample
        self.windowMs = windowMs
    }
}

// MARK: - 监测器

public struct PerfPowerMonitorOptions: PerfMonitorOptions {
    /// 电量采样周期。
    ///
    /// 默认 1 分钟：电量本身变化很慢，采太密只会产生大量重复值。
    public var batteryInterval: PerfDuration = .minutes(1)

    /// 是否采集电量。
    ///
    /// iOS 上需要开启 `UIDevice.isBatteryMonitoringEnabled`，
    /// 这会带来轻微的系统开销，所以做成可关。
    public var tracksBattery: Bool = true

    /// 热状态变化时是否立即上报。
    public var reportsThermalChanges: Bool = true

    public init() {}
}

/// 电量与热状态监测。
public actor PerfPowerMonitor: PerfMonitor {
    public nonisolated static let descriptor = PerfMonitorDescriptor(
        id: PerfPower.monitorID,
        displayName: "电量与热状态",
        kinds: [PerfThermalSample.kind, PerfBatterySample.kind],
        platforms: .all
    )

    private var options: PerfPowerMonitorOptions
    private let context: PerfMonitorContext

    private var batteryToken: PerfCadenceToken?
    private var thermalObserver: NSObjectProtocol?
    private var previousBatteryLevel: Double?
    private var previousBatterySampleUptime: UInt64?
    private var lastReportedThermalState: PerfThermalSample.State?

    public init(options: PerfPowerMonitorOptions, context: PerfMonitorContext) {
        self.options = options
        self.context = context.scoped(to: Self.descriptor.id)
    }

    public func start() async throws {
        guard batteryToken == nil, thermalObserver == nil else { return }

        await enableBatteryMonitoringIfNeeded()
        reportThermalState(reason: "启动")

        if options.reportsThermalChanges {
            installThermalObserver()
        }

        if options.tracksBattery {
            batteryToken = context.scheduler.schedule(
                label: "\(Self.descriptor.id).battery",
                interval: options.batteryInterval
            ) { [weak self] tick in
                await self?.sampleBattery(at: tick)
            }
        }
    }

    public func stop() async {
        if let batteryToken {
            context.scheduler.cancel(batteryToken)
        }
        batteryToken = nil

        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        thermalObserver = nil
    }

    public func apply(_ options: PerfPowerMonitorOptions) async {
        self.options = options
    }

    // MARK: - 热状态

    private func installThermalObserver() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.reportThermalState(reason: "变化") }
        }
    }

    private func reportThermalState(reason: String) {
        let state = Self.currentThermalState()
        // 只在状态真的变了时上报。热状态变化是低频事件，
        // 每次采样都记一条只会产生大量重复值。
        guard state != lastReportedThermalState else { return }
        lastReportedThermalState = state

        let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        context.recorder.record(
            PerfThermalSample(state: state, isLowPowerModeEnabled: isLowPower),
            severity: state.isThrottling ? .warning : .info
        )
        context.log.debug("热状态\(reason)：\(state.rawValue)，低电量模式：\(isLowPower)")
    }

    private static func currentThermalState() -> PerfThermalSample.State {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }

    // MARK: - 电量

    private func enableBatteryMonitoringIfNeeded() async {
        guard options.tracksBattery else { return }
        #if os(iOS)
        // 不开这个开关，batteryLevel 恒为 -1。
        // 这里不能用 MainActor.assumeIsolated：本方法从 actor 的 start() 调用，
        // 执行器不是主线程，assumeIsolated 会直接触发运行时崩溃。
        await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        #endif
    }

    private func sampleBattery(at tick: PerfTick) async {
        let reading = await Self.readBattery()

        let windowNanos = previousBatterySampleUptime.map {
            tick.uptimeNanos > $0 ? tick.uptimeNanos - $0 : 0
        } ?? options.batteryInterval.nanoseconds
        previousBatterySampleUptime = tick.uptimeNanos

        let delta = zip2Optional(reading.levelPercent, previousBatteryLevel).map { $0 - $1 }
        previousBatteryLevel = reading.levelPercent

        context.recorder.record(
            PerfBatterySample(
                levelPercent: reading.levelPercent,
                isCharging: reading.isCharging,
                deltaSinceLastSample: delta,
                windowMs: Double(windowNanos) / 1_000_000
            ),
            severity: .info,
            timestamp: tick.date,
            uptimeNanos: tick.uptimeNanos
        )
    }

    private func zip2Optional<T>(_ a: T?, _ b: T?) -> (T, T)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    /// 读取电量。平台差异收敛在这里。
    private static func readBattery() async -> (levelPercent: Double?, isCharging: Bool?) {
        #if os(iOS)
        // 同样不能用 assumeIsolated：本方法从调度器的后台回调链调用，
        // 不保证在主线程。UIDevice 的 batteryLevel 访问需要主线程。
        let device = await MainActor.run { () -> (Float, UIDevice.BatteryState) in
            (UIDevice.current.batteryLevel, UIDevice.current.batteryState)
        }
        // 监测未开启或取不到时系统返回 -1，不能当成 0% 上报
        let level = device.0 >= 0 ? Double(device.0) * 100 : nil
        let charging: Bool? = switch device.1 {
        case .charging, .full: true
        case .unplugged: false
        default: nil
        }
        return (level, charging)

        #elseif os(macOS)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let description = IOPSGetPowerSourceDescription(blob, first)?
                  .takeUnretainedValue() as? [String: Any]
        else { return (nil, nil) }

        let current = description[kIOPSCurrentCapacityKey] as? Int
        let max = description[kIOPSMaxCapacityKey] as? Int
        let level = (current.flatMap { c in max.map { m in m > 0 ? Double(c) / Double(m) * 100 : nil } } ?? nil)

        return (level, description[kIOPSIsChargingKey] as? Bool)

        #else
        return (nil, nil)
        #endif
    }
}
