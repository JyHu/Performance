import Foundation
import PerformanceCore
import PerformanceSystemKit

/// CPU / 内存 / 线程数监测的配置。
public struct PerfResourceMonitorOptions: PerfMonitorOptions {
    /// 采样周期。会被对齐到调度器基频的整数倍。
    public var interval: PerfDuration = .seconds(1)

    /// CPU 占用率告警阈值（百分比）。
    ///
    /// 默认 80 而不是 100：单核满载对用户体验的影响，
    /// 在多核设备上早在总占用率到 100% 之前就已经发生。
    public var cpuWarningPercent: Double = 80
    public var cpuCriticalPercent: Double = 150

    /// 内存足迹告警阈值（MB）。
    public var memoryWarningMB: Double = 400
    public var memoryCriticalMB: Double = 700

    /// 相对基线的内存增长告警阈值（MB）。用于发现泄漏。
    public var memoryGrowthWarningMB: Double = 150

    /// 线程数告警阈值。
    public var threadCountWarning: Int = 80

    /// 每次采样记录占用最高的几个线程。
    ///
    /// 只记 Top N 而不是全部：一个 app 常有几十个线程，
    /// 全记会让数据量膨胀数倍，而排查真正需要的只有最忙的那几个。
    public var topThreadCount: Int = 5

    /// 是否采集内核活动（缺页、上下文切换）。
    public var tracksKernelActivity: Bool = true

    /// 低于告警阈值的常规采样是否也记录。
    ///
    /// 关掉可以大幅减少数据量，但也就失去了「问题发生前趋势如何」的上下文——
    /// 而那恰恰是排查内存泄漏和性能劣化时最需要的。默认保留。
    public var recordsNormalSamples: Bool = true

    public init() {}
}

/// CPU / 内存 / 线程数监测。
public actor PerfResourceMonitor: PerfMonitor {
    public nonisolated static let descriptor = PerfMonitorDescriptor(
        id: PerfResource.monitorID,
        displayName: "资源占用",
        kinds: [
            PerfCPUSample.kind,
            PerfMemorySample.kind,
            PerfKernelActivitySample.kind,
        ],
        platforms: .all
    )

    private var options: PerfResourceMonitorOptions
    private let context: PerfMonitorContext

    private var cadenceToken: PerfCadenceToken?

    /// 上一次采样的累计量，用于做差分。
    private var previousCPUTime: PerfCPUTime?
    private var previousKernelActivity: PerfProcessMetrics.KernelActivity?
    private var previousSampleUptime: UInt64?

    /// 本 session 首次采样的内存足迹，作为增长量的基线。
    private var baselineFootprintBytes: UInt64?

    public init(options: PerfResourceMonitorOptions, context: PerfMonitorContext) {
        self.options = options
        self.context = context.scoped(to: Self.descriptor.id)
    }

    public func start() async throws {
        guard cadenceToken == nil else { return }

        // 立刻采一次，建立基线与差分起点。
        // 否则第一条有效数据要等一个完整周期之后才出现，
        // 而启动后的头几秒往往正是资源占用的高峰。
        captureBaseline()

        cadenceToken = context.scheduler.schedule(
            label: Self.descriptor.id.rawValue,
            interval: options.interval
        ) { [weak self] tick in
            await self?.sample(at: tick)
        }
    }

    public func stop() async {
        if let cadenceToken {
            context.scheduler.cancel(cadenceToken)
        }
        cadenceToken = nil
        previousCPUTime = nil
        previousKernelActivity = nil
        previousSampleUptime = nil
    }

    public func apply(_ options: PerfResourceMonitorOptions) async {
        let intervalChanged = options.interval != self.options.interval
        self.options = options

        // 周期变了必须重新注册——调度器是按固定分频触发的，
        // 光改字段不会影响已经注册的 cadence。
        guard intervalChanged, let token = cadenceToken else { return }
        context.scheduler.cancel(token)
        cadenceToken = context.scheduler.schedule(
            label: Self.descriptor.id.rawValue,
            interval: options.interval
        ) { [weak self] tick in
            await self?.sample(at: tick)
        }
    }

    // MARK: - 采样

    private func captureBaseline() {
        previousCPUTime = PerfCPUMetrics.processCPUTime()
        previousKernelActivity = PerfProcessMetrics.kernelActivity()
        previousSampleUptime = context.clock.uptimeNanos
        baselineFootprintBytes = PerfMemoryMetrics.current().footprintBytes
    }

    func sample(at tick: PerfTick) {
        let window = elapsedWindow(now: tick.uptimeNanos)
        previousSampleUptime = tick.uptimeNanos

        sampleCPU(window: window, tick: tick)
        sampleMemory(tick: tick)
        if options.tracksKernelActivity {
            sampleKernelActivity(window: window, tick: tick)
        }
    }

    private func elapsedWindow(now: UInt64) -> PerfDuration {
        guard let previous = previousSampleUptime, now > previous else {
            return options.interval
        }
        return PerfDuration(nanoseconds: now - previous)
    }

    private func sampleCPU(window: PerfDuration, tick: PerfTick) {
        guard let current = PerfCPUMetrics.processCPUTime() else { return }
        defer { previousCPUTime = current }

        // 没有上一次就算不出占用率。跳过这一轮而不是上报一个 0——
        // 0 会被当成「CPU 空闲」，而真相是「还不知道」。
        guard let previous = previousCPUTime else { return }

        let percent = current.usagePercent(since: previous, elapsed: window)
        let threads = PerfCPUMetrics.threadCPU(includeIdle: false)
        let severity = cpuSeverity(percent)

        guard severity > .info || options.recordsNormalSamples else { return }

        let top = threads
            .sorted { $0.usagePercent > $1.usagePercent }
            .prefix(options.topThreadCount)
            .map { PerfThreadUsage(name: $0.name, isMain: $0.isMain, percent: $0.usagePercent) }

        context.recorder.record(
            PerfCPUSample(
                processPercent: percent,
                windowMs: window.milliseconds,
                topThreads: Array(top),
                threadCount: PerfCPUMetrics.threadCount()
            ),
            severity: max(severity, threadCountSeverity()),
            timestamp: tick.date,
            uptimeNanos: tick.uptimeNanos
        )
    }

    private func sampleMemory(tick: PerfTick) {
        let metrics = PerfMemoryMetrics.current()

        if baselineFootprintBytes == nil {
            baselineFootprintBytes = metrics.footprintBytes
        }
        let baseline = baselineFootprintBytes ?? metrics.footprintBytes
        let growthBytes = metrics.footprintBytes > baseline ? metrics.footprintBytes - baseline : 0
        let growthMB = Double(growthBytes) / 1_048_576

        let severity = memorySeverity(footprintMB: metrics.footprintMegabytes, growthMB: growthMB)
        guard severity > .info || options.recordsNormalSamples else { return }

        context.recorder.record(
            PerfMemorySample(
                footprintMB: metrics.footprintMegabytes,
                residentMB: Double(metrics.residentBytes) / 1_048_576,
                growthSinceBaselineMB: growthMB,
                availableToProcessMB: metrics.availableToProcessBytes.map { Double($0) / 1_048_576 },
                systemAvailableMB: metrics.systemAvailableBytes.map { Double($0) / 1_048_576 }
            ),
            severity: severity,
            timestamp: tick.date,
            uptimeNanos: tick.uptimeNanos
        )
    }

    private func sampleKernelActivity(window: PerfDuration, tick: PerfTick) {
        guard let current = PerfProcessMetrics.kernelActivity() else { return }
        defer { previousKernelActivity = current }
        guard let previous = previousKernelActivity else { return }

        let sample = PerfKernelActivitySample(
            pageinsDelta: current.pageins &- min(current.pageins, previous.pageins),
            contextSwitchesDelta: current.contextSwitches &- min(current.contextSwitches, previous.contextSwitches),
            windowMs: window.milliseconds
        )

        guard options.recordsNormalSamples else { return }
        context.recorder.record(
            sample,
            // 内核活动本身不直接定级：它的意义在于与 CPU/内存对照，
            // 单独看一个「上下文切换 5000 次」无法判断是否异常。
            severity: .debug,
            timestamp: tick.date,
            uptimeNanos: tick.uptimeNanos
        )
    }

    // MARK: - 定级

    private func cpuSeverity(_ percent: Double) -> PerfSeverity {
        if percent >= options.cpuCriticalPercent { return .error }
        if percent >= options.cpuWarningPercent { return .warning }
        return .info
    }

    private func memorySeverity(footprintMB: Double, growthMB: Double) -> PerfSeverity {
        if footprintMB >= options.memoryCriticalMB { return .critical }
        if footprintMB >= options.memoryWarningMB { return .warning }
        // 绝对值不高但持续增长，同样值得关注——这是泄漏的典型形态
        if growthMB >= options.memoryGrowthWarningMB { return .warning }
        return .info
    }

    private func threadCountSeverity() -> PerfSeverity {
        PerfCPUMetrics.threadCount() >= options.threadCountWarning ? .warning : .info
    }
}
