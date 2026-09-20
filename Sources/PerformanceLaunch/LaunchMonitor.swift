import CoreFoundation
import Foundation
import PerformanceCore
import PerformanceSystemKit

// MARK: - 载荷

/// 冷启动耗时分解。
public struct PerfColdLaunchSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "launch.cold"

    /// 进程创建 → 首帧（或其代理指标）的总耗时。
    public let totalMs: Double
    /// 进程创建 → `main()` 入口。主要是动态库加载与 runtime 初始化。
    ///
    /// 业务方没在 `main()` 里打点时为 nil。
    public let preMainMs: Double?
    /// 进程创建 → app 完成启动回调。
    public let didFinishLaunchingMs: Double?
    /// 进程创建 → 性能框架开始工作。
    ///
    /// **这个字段决定了上面的数据有多可信**：框架起得越晚，
    /// 启动前期就有越长一段是没被观测到的。如实上报，
    /// 免得把「没测到」误读成「没耗时」。
    public let frameworkReadyMs: Double
    /// 首帧时刻的来源。
    public let firstFrameSource: FirstFrameSource

    /// 首帧时刻是怎么确定的。
    public enum FirstFrameSource: String, Codable, Sendable {
        /// 业务方显式调用 `markFirstFrame()`。最准确。
        case explicit
        /// 框架用「app 激活后首次主 RunLoop 空闲」做的近似。
        ///
        /// 它一般略晚于真实首帧，因为要等本轮 RunLoop 的全部工作做完。
        case runLoopIdleApproximation
    }

    public init(
        totalMs: Double,
        preMainMs: Double?,
        didFinishLaunchingMs: Double?,
        frameworkReadyMs: Double,
        firstFrameSource: FirstFrameSource
    ) {
        self.totalMs = totalMs
        self.preMainMs = preMainMs
        self.didFinishLaunchingMs = didFinishLaunchingMs
        self.frameworkReadyMs = frameworkReadyMs
        self.firstFrameSource = firstFrameSource
    }
}

/// 热启动耗时：从回到前台到重新可交互。
public struct PerfWarmLaunchSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "launch.warm"

    public let totalMs: Double
    /// 本次回到前台前，在后台待了多久。
    ///
    /// 后台停留越久，系统越可能已经回收了资源，热启动也就越慢——
    /// 没有这个维度，热启动耗时的波动会显得毫无规律。
    public let backgroundDurationMs: Double?

    public init(totalMs: Double, backgroundDurationMs: Double?) {
        self.totalMs = totalMs
        self.backgroundDurationMs = backgroundDurationMs
    }
}

/// 业务自定义的启动阶段。
public struct PerfLaunchStageSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "launch.stage"

    public let name: String
    /// 相对进程创建时刻的偏移。
    public let offsetFromProcessStartMs: Double
    /// 相对上一个阶段的耗时。
    public let durationSincePreviousMs: Double?

    public init(name: String, offsetFromProcessStartMs: Double, durationSincePreviousMs: Double?) {
        self.name = name
        self.offsetFromProcessStartMs = offsetFromProcessStartMs
        self.durationSincePreviousMs = durationSincePreviousMs
    }
}

// MARK: - 监测器

public struct PerfLaunchMonitorOptions: PerfMonitorOptions {
    /// 冷启动超过此值告警。
    public var coldLaunchWarningThreshold: PerfDuration = .seconds(2)
    public var coldLaunchCriticalThreshold: PerfDuration = .seconds(5)

    /// 热启动超过此值告警。
    public var warmLaunchWarningThreshold: PerfDuration = .milliseconds(500)

    /// 等待业务方显式标记首帧的时长。
    ///
    /// 超时后退回「首次 RunLoop 空闲」的近似值。
    /// 设这个等待是为了优先用准确数据，但不能无限等——
    /// 业务方可能根本没接入那个 API。
    public var explicitFirstFrameGracePeriod: PerfDuration = .seconds(3)

    /// 是否上报业务自定义的启动阶段。
    public var reportsCustomStages: Bool = true

    public init() {}
}

/// 启动耗时监测。
public actor PerfLaunchMonitor: PerfMonitor {
    public nonisolated static let descriptor = PerfMonitorDescriptor(
        id: PerfLaunch.monitorID,
        displayName: "启动耗时",
        kinds: [
            PerfColdLaunchSample.kind,
            PerfWarmLaunchSample.kind,
            PerfLaunchStageSample.kind,
        ],
        platforms: .all
    )

    private var options: PerfLaunchMonitorOptions
    private let context: PerfMonitorContext
    private let timeline: PerfLaunchTimeline

    private var lifecycleToken: PerfLifecycleToken?
    private var idleObserver: FirstIdleObserver?

    private var hasReportedColdLaunch = false
    private var didFinishLaunchingUptime: UInt64?
    private var backgroundedAtUptime: UInt64?
    private var foregroundingStartedAtUptime: UInt64?

    /// 「首次 RunLoop 空闲」的时刻，作为首帧的代理指标。
    private var firstIdleUptime: UInt64?

    public init(options: PerfLaunchMonitorOptions, context: PerfMonitorContext) {
        self.init(options: options, context: context, timeline: .shared)
    }

    /// 注入独立的时间线，供测试使用。
    public init(
        options: PerfLaunchMonitorOptions,
        context: PerfMonitorContext,
        timeline: PerfLaunchTimeline
    ) {
        self.options = options
        self.context = context.scoped(to: Self.descriptor.id)
        self.timeline = timeline
    }

    public func start() async throws {
        guard lifecycleToken == nil else { return }

        lifecycleToken = context.lifecycle.observe { [weak self] event, date in
            Task { await self?.handle(event: event, at: date) }
        }

        installIdleObserver()
        reportCustomStages()

        // 框架可能在 app 早就启动完之后才被配置（例如按配置开关延迟启用）。
        // 这种情况下等不到 didFinishLaunching 通知了，直接按现状结算，
        // 否则冷启动数据会永远缺失。
        scheduleColdLaunchFallback()
    }

    public func stop() async {
        if let lifecycleToken {
            context.lifecycle.removeObserver(lifecycleToken)
        }
        lifecycleToken = nil
        removeIdleObserver()
    }

    public func apply(_ options: PerfLaunchMonitorOptions) async {
        self.options = options
    }

    // MARK: - 生命周期

    private func handle(event: PerfAppLifecycleEvent, at date: Date) {
        switch event {
        case .didFinishLaunching:
            didFinishLaunchingUptime = context.clock.uptimeNanos

        case .didEnterBackground, .willResignActive:
            backgroundedAtUptime = context.clock.uptimeNanos

        case .willEnterForeground:
            foregroundingStartedAtUptime = context.clock.uptimeNanos

        case .didBecomeActive:
            reportWarmLaunchIfNeeded(at: date)

        default:
            break
        }
    }

    private func reportWarmLaunchIfNeeded(at date: Date) {
        // 冷启动过程中也会走到 didBecomeActive，那不算热启动
        guard hasReportedColdLaunch, let start = foregroundingStartedAtUptime else { return }
        foregroundingStartedAtUptime = nil

        let now = context.clock.uptimeNanos
        guard now > start else { return }
        let totalNanos = now - start

        let backgroundNanos = backgroundedAtUptime.map { start > $0 ? start - $0 : 0 }
        backgroundedAtUptime = nil

        context.recorder.record(
            PerfWarmLaunchSample(
                totalMs: Double(totalNanos) / 1_000_000,
                backgroundDurationMs: backgroundNanos.map { Double($0) / 1_000_000 }
            ),
            severity: totalNanos >= options.warmLaunchWarningThreshold.nanoseconds ? .warning : .info,
            thread: .main,
            timestamp: date,
            uptimeNanos: now
        )
    }

    // MARK: - 冷启动

    /// 监听首次主 RunLoop 空闲，作为首帧的代理指标。
    private func installIdleObserver() {
        guard idleObserver == nil else { return }

        let observer = FirstIdleObserver(clock: context.clock)
        idleObserver = observer
        observer.install { [weak self] uptime in
            Task { await self?.recordFirstIdle(at: uptime) }
        }
    }

    private func removeIdleObserver() {
        idleObserver?.remove()
        idleObserver = nil
    }

    private func recordFirstIdle(at uptime: UInt64) {
        guard firstIdleUptime == nil else { return }
        firstIdleUptime = uptime
        removeIdleObserver()
    }

    private func scheduleColdLaunchFallback() {
        let grace = options.explicitFirstFrameGracePeriod
        Task { [weak self] in
            // 优先等业务方显式标记首帧；等不到就用代理指标结算
            try? await Task.sleep(nanoseconds: grace.nanoseconds)
            await self?.reportColdLaunchIfNeeded()
        }
    }

    func reportColdLaunchIfNeeded() {
        guard !hasReportedColdLaunch else { return }

        guard let processStart = timeline.processStartDate else {
            context.log.warning("取不到进程创建时间，跳过冷启动统计")
            hasReportedColdLaunch = true
            return
        }

        // 单调时钟不能跨进程使用，所以「进程创建 → 框架加载」这一段
        // 只能用墙上时钟算；之后的各段再用单调时钟，避免受系统改时间影响。
        let processStartToFrameworkLoad = timeline.frameworkLoadDate.timeIntervalSince(processStart)
        guard processStartToFrameworkLoad >= 0 else {
            context.log.warning("进程创建时间晚于框架加载时间，数据异常，跳过")
            hasReportedColdLaunch = true
            return
        }

        let loadUptime = timeline.frameworkLoadUptime
        func offsetFromProcessStart(_ uptime: UInt64) -> Double {
            let sinceLoad = uptime > loadUptime ? Double(uptime - loadUptime) / 1_000_000_000 : 0
            return (processStartToFrameworkLoad + sinceLoad) * 1_000
        }

        let explicitFirstFrame = timeline.uptime(of: PerfLaunchTimeline.Mark.firstFrame)
        let source: PerfColdLaunchSample.FirstFrameSource =
            explicitFirstFrame != nil ? .explicit : .runLoopIdleApproximation

        guard let firstFrameUptime = explicitFirstFrame ?? firstIdleUptime else {
            context.log.warning("既没有显式首帧标记，也没观测到 RunLoop 空闲，跳过冷启动统计")
            return
        }

        hasReportedColdLaunch = true

        let totalMs = offsetFromProcessStart(firstFrameUptime)
        let severity: PerfSeverity =
            if totalMs >= options.coldLaunchCriticalThreshold.milliseconds { .error }
            else if totalMs >= options.coldLaunchWarningThreshold.milliseconds { .warning }
            else { .info }

        context.recorder.record(
            PerfColdLaunchSample(
                totalMs: totalMs,
                preMainMs: timeline.uptime(of: PerfLaunchTimeline.Mark.main)
                    .map(offsetFromProcessStart),
                didFinishLaunchingMs: didFinishLaunchingUptime.map(offsetFromProcessStart),
                frameworkReadyMs: processStartToFrameworkLoad * 1_000,
                firstFrameSource: source
            ),
            severity: severity,
            thread: .main,
            timestamp: timeline.date(of: PerfLaunchTimeline.Mark.firstFrame) ?? context.clock.now,
            uptimeNanos: firstFrameUptime
        )
    }

    // MARK: - 自定义阶段

    private func reportCustomStages() {
        guard options.reportsCustomStages else { return }
        guard let processStart = timeline.processStartDate else { return }

        let processStartToLoad = timeline.frameworkLoadDate.timeIntervalSince(processStart)
        let loadUptime = timeline.frameworkLoadUptime

        var previousOffsetMs: Double?
        for mark in timeline.allMarks() {
            let sinceLoad = mark.uptime > loadUptime
                ? Double(mark.uptime - loadUptime) / 1_000_000_000
                : 0
            let offsetMs = (processStartToLoad + sinceLoad) * 1_000

            context.recorder.record(
                PerfLaunchStageSample(
                    name: mark.name,
                    offsetFromProcessStartMs: offsetMs,
                    durationSincePreviousMs: previousOffsetMs.map { offsetMs - $0 }
                ),
                severity: .info,
                thread: .main
            )
            previousOffsetMs = offsetMs
        }
    }
}
