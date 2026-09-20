import Foundation
import PerformanceCore

/// FPS / 掉帧监测的配置。
public struct PerfRenderingMonitorOptions: PerfMonitorOptions {
    /// 帧率统计窗口。
    public var windowInterval: PerfDuration = .seconds(1)

    /// 判定掉帧的倍数：本帧耗时超过 `目标间隔 × 该值` 即算一次掉帧。
    ///
    /// 默认 2.0 —— 也就是「整整错过了一帧」。设成 1.0 会把正常的时序抖动
    /// 全都报成掉帧，数据噪声大到无法使用。
    public var jankThresholdMultiplier: Double = 2.0

    /// 单帧超过这个倍数时定级为 error。
    public var severeJankThresholdMultiplier: Double = 6.0

    /// 是否为每次掉帧单独记录一条事件。
    ///
    /// 关掉只保留窗口聚合。滚动列表时掉帧可能很密集，
    /// 逐帧记录会瞬间灌满缓冲，把其他类型的数据挤掉。
    public var recordsIndividualJank: Bool = true

    /// 单个窗口内最多记录多少条掉帧事件，超出部分只计入聚合。
    public var maxJankEventsPerWindow: Int = 10

    /// 平均帧率低于此值时告警。
    ///
    /// 用**相对**目标帧率的比例而不是绝对值：60Hz 设备上 50fps 尚可，
    /// 120Hz 设备上 50fps 已经是严重问题。
    public var fpsWarningRatio: Double = 0.85
    public var fpsCriticalRatio: Double = 0.6

    /// 期望的回调频率（Hz）。nil 表示跟随屏幕刷新率。
    public var preferredRefreshRate: Int?

    /// 是否记录没有异常的常规窗口。
    public var recordsNormalSamples: Bool = true

    public init() {}
}

/// FPS / Jank / 掉帧监测。
public actor PerfRenderingMonitor: PerfMonitor {
    public nonisolated static let descriptor = PerfMonitorDescriptor(
        id: PerfRendering.monitorID,
        displayName: "渲染帧率",
        kinds: [PerfFPSSample.kind, PerfJankEvent.kind],
        platforms: .all
    )

    private var options: PerfRenderingMonitorOptions
    private let context: PerfMonitorContext
    private let driverFactory: @Sendable (PerfRenderingMonitorOptions) -> any PerfDisplayLinkDriver

    private var driver: (any PerfDisplayLinkDriver)?
    private var cadenceToken: PerfCadenceToken?
    private var accumulator: FrameAccumulator?

    public init(options: PerfRenderingMonitorOptions, context: PerfMonitorContext) {
        self.init(options: options, context: context) { options in
            PerfDisplayLinkFactory.makeDriver(preferredRefreshRate: options.preferredRefreshRate)
        }
    }

    /// 注入自定义驱动，供测试使用。
    ///
    /// 有了它，「模拟 120 帧、其中第 40 帧卡了 200ms」就是一串同步调用，
    /// 不需要真的跑起一个窗口去等屏幕刷新。
    public init(
        options: PerfRenderingMonitorOptions,
        context: PerfMonitorContext,
        driverFactory: @escaping @Sendable (PerfRenderingMonitorOptions) -> any PerfDisplayLinkDriver
    ) {
        self.options = options
        self.context = context.scoped(to: Self.descriptor.id)
        self.driverFactory = driverFactory
    }

    public func start() async throws {
        guard driver == nil else { return }

        let accumulator = FrameAccumulator(
            jankThresholdMultiplier: options.jankThresholdMultiplier
        )
        self.accumulator = accumulator

        let driver = driverFactory(options)
        self.driver = driver

        let recorder = context.recorder
        let options = options

        try driver.start { tick in
            // 这个闭包在 iOS 上跑在**主线程**。
            // 里面只做一次加锁的 O(1) 累加，以及（必要时）一次 O(1) 的环形缓冲入队——
            // 绝不能做 I/O、编码或跨线程等待，否则监控自己就成了掉帧的来源。
            guard let observed = accumulator.observe(tick: tick) else { return }

            guard observed.isJank, options.recordsIndividualJank,
                  observed.jankIndexInWindow < options.maxJankEventsPerWindow
            else { return }

            recorder.record(
                PerfJankEvent(
                    frameMs: observed.frameSeconds * 1_000,
                    targetFrameMs: observed.targetSeconds * 1_000,
                    droppedFrames: observed.droppedFrames
                ),
                severity: observed.frameSeconds >= observed.targetSeconds * options.severeJankThresholdMultiplier
                    ? .error
                    : .warning,
                thread: tick.isMainThread ? .main : nil
            )
        }

        cadenceToken = context.scheduler.schedule(
            label: Self.descriptor.id.rawValue,
            interval: options.windowInterval
        ) { [weak self] tick in
            await self?.emitWindow(at: tick)
        }
    }

    public func stop() async {
        driver?.stop()
        driver = nil
        accumulator = nil

        if let cadenceToken {
            context.scheduler.cancel(cadenceToken)
        }
        cadenceToken = nil
    }

    public func apply(_ options: PerfRenderingMonitorOptions) async {
        self.options = options
        // 阈值类参数下次窗口即生效；驱动相关参数需要重启才能变更。
        accumulator?.updateThreshold(options.jankThresholdMultiplier)
    }

    // MARK: - 窗口聚合

    func emitWindow(at tick: PerfTick) {
        guard let window = accumulator?.drain() else { return }
        guard window.frameCount > 0 else { return }

        let windowSeconds = window.elapsedSeconds
        guard windowSeconds > 0 else { return }

        let fps = Double(window.frameCount) / windowSeconds
        let targetFPS = window.averageTargetSeconds > 0 ? 1 / window.averageTargetSeconds : 60
        let ratio = targetFPS > 0 ? fps / targetFPS : 1

        let severity: PerfSeverity =
            if ratio <= options.fpsCriticalRatio { .error }
            else if ratio <= options.fpsWarningRatio { .warning }
            else { .info }

        guard severity > .info || options.recordsNormalSamples else { return }

        context.recorder.record(
            PerfFPSSample(
                fps: fps,
                targetFPS: targetFPS,
                frameCount: window.frameCount,
                windowMs: windowSeconds * 1_000,
                jankFrameCount: window.jankCount,
                worstFrameMs: window.worstFrameSeconds * 1_000,
                hitchTimeRatio: window.hitchSeconds / windowSeconds
            ),
            severity: severity,
            timestamp: tick.date,
            uptimeNanos: tick.uptimeNanos
        )
    }
}

// MARK: - 帧数据累加

/// 在帧回调线程与聚合线程之间传递数据。
///
/// 帧回调可能在主线程（iOS 的 CADisplayLink）或专用线程（macOS 的 CVDisplayLink），
/// 而聚合发生在调度器的后台任务里，所以需要同步。临界区只有几条算术指令。
final class FrameAccumulator: @unchecked Sendable {
    struct Observation {
        let frameSeconds: Double
        let targetSeconds: Double
        let isJank: Bool
        let droppedFrames: Int
        /// 本窗口内这是第几次掉帧，用于限流。
        let jankIndexInWindow: Int
    }

    struct Window {
        let frameCount: Int
        let elapsedSeconds: Double
        let averageTargetSeconds: Double
        let jankCount: Int
        let worstFrameSeconds: Double
        /// 所有超时帧多花的时间总和。
        let hitchSeconds: Double
    }

    private let lock = PerfLock()
    private var jankThresholdMultiplier: Double

    private var previousTimestamp: CFTimeInterval?
    private var frameCount = 0
    private var elapsedSeconds: Double = 0
    private var targetSecondsSum: Double = 0
    private var jankCount = 0
    private var worstFrameSeconds: Double = 0
    private var hitchSeconds: Double = 0

    init(jankThresholdMultiplier: Double) {
        self.jankThresholdMultiplier = jankThresholdMultiplier
    }

    func updateThreshold(_ value: Double) {
        lock.withLock { jankThresholdMultiplier = value }
    }

    /// 记录一帧。首帧因为没有前一帧时间戳而返回 nil。
    func observe(tick: PerfFrameTick) -> Observation? {
        lock.lock()
        defer { lock.unlock() }

        guard let previous = previousTimestamp else {
            previousTimestamp = tick.timestamp
            return nil
        }
        previousTimestamp = tick.timestamp

        let frameSeconds = tick.timestamp - previous
        // 时间戳回退或出现荒谬的巨大间隔（app 切后台再回来），直接丢弃这一帧。
        // 不丢的话，一次后台驻留会被记成一次 30 秒的「卡顿」。
        guard frameSeconds > 0, frameSeconds < 10 else { return nil }

        let targetSeconds = tick.targetFrameInterval
        frameCount += 1
        elapsedSeconds += frameSeconds
        targetSecondsSum += targetSeconds
        worstFrameSeconds = max(worstFrameSeconds, frameSeconds)

        let overshoot = frameSeconds - targetSeconds
        if overshoot > 0 {
            hitchSeconds += overshoot
        }

        let isJank = frameSeconds > targetSeconds * jankThresholdMultiplier
        var jankIndex = 0
        if isJank {
            jankIndex = jankCount
            jankCount += 1
        }

        return Observation(
            frameSeconds: frameSeconds,
            targetSeconds: targetSeconds,
            isJank: isJank,
            droppedFrames: targetSeconds > 0 ? max(0, Int((frameSeconds / targetSeconds).rounded(.down)) - 1) : 0,
            jankIndexInWindow: jankIndex
        )
    }

    /// 取走本窗口的统计并重置。
    ///
    /// 不重置 `previousTimestamp`：窗口边界不该被当成一次帧间断裂，
    /// 否则每个窗口的第一帧都会被丢掉。
    func drain() -> Window? {
        lock.lock()
        defer { lock.unlock() }

        guard frameCount > 0 else { return nil }

        let window = Window(
            frameCount: frameCount,
            elapsedSeconds: elapsedSeconds,
            averageTargetSeconds: targetSecondsSum / Double(frameCount),
            jankCount: jankCount,
            worstFrameSeconds: worstFrameSeconds,
            hitchSeconds: hitchSeconds
        )

        frameCount = 0
        elapsedSeconds = 0
        targetSecondsSum = 0
        jankCount = 0
        worstFrameSeconds = 0
        hitchSeconds = 0

        return window
    }
}
