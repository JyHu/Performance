import Foundation
import PerformanceCore

/// 主线程健康监测的配置。
public struct PerfHangMonitorOptions: PerfMonitorOptions {
    /// 单次 RunLoop 迭代超过此值即记一次顿挫。
    ///
    /// 250ms 是「用户能明确察觉到界面没反应」的量级。
    /// 设到 16ms 那种一帧的量级会产生海量噪声——
    /// 主线程偶尔多花一帧是完全正常的。
    public var hitchThreshold: PerfDuration = .milliseconds(250)

    /// 主线程持续无响应超过此值即判定为 ANR。
    public var unresponsiveThreshold: PerfDuration = .seconds(2)

    /// 持续无响应超过此值升级为严重级别。
    ///
    /// 8 秒接近系统看门狗介入的量级，到这一步进程随时可能被杀。
    public var severeThreshold: PerfDuration = .seconds(8)

    /// watchdog 检查周期。
    public var checkInterval: PerfDuration = .milliseconds(250)

    /// 连续多少次检查的寄存器完全不变即判定为死锁。
    ///
    /// 用寄存器而不是耗时来区分：跑得慢的代码 PC 会一直变，
    /// 真卡死的不会。只看耗时无法区分「死锁」和「在算一个很大的循环」。
    public var deadlockUnchangedSampleCount: Int = 4

    /// 是否在 ANR 时抓取主线程堆栈。
    public var capturesStackOnHang: Bool = true

    /// 死锁时是否抓取全部线程的堆栈。
    ///
    /// 死锁必然涉及至少两方，只看主线程无法知道锁被谁持有。
    /// 代价是数据量大，所以只在死锁这种低频事件上做。
    public var capturesAllThreadsOnDeadlock: Bool = true

    /// 落盘时每个堆栈最多保留多少帧。
    public var maxStackFrames: Int = 64

    /// 是否记录 RunLoop 阶段分解。
    public var tracksRunLoopPhases: Bool = false

    /// 阶段分解只在迭代耗时超过此值时记录，避免海量正常迭代淹没数据。
    public var phaseRecordingThreshold: PerfDuration = .milliseconds(100)

    /// 是否测量主队列排队时延。
    public var tracksQueueLatency: Bool = true

    /// 排队时延的探测周期。
    public var queueLatencyProbeInterval: PerfDuration = .seconds(1)

    /// 排队时延超过此值才记录。
    public var queueLatencyThreshold: PerfDuration = .milliseconds(50)

    public init() {}
}

/// 主线程健康监测：顿挫 / ANR / 死锁 / RunLoop 阶段 / 主队列时延。
///
/// 四类问题共用**一个** RunLoop observer 和**一个** watchdog。
/// 上一版把 ANR 与死锁拆成两个模块，各建队列、各建定时器、
/// 各自用 semaphore 往主队列投探针，而且两者默认都开——
/// 主线程被两路互不知情的探针同时打扰，开销翻倍，结果还可能互相干扰。
public actor PerfHangMonitor: PerfMonitor {
    public nonisolated static let descriptor = PerfMonitorDescriptor(
        id: PerfHang.monitorID,
        displayName: "主线程健康",
        kinds: [
            PerfHangEvent.kind,
            PerfDeadlockEvent.kind,
            PerfHitchEvent.kind,
            PerfRunLoopPhaseSample.kind,
            PerfQueueLatencySample.kind,
        ],
        platforms: .all
    )

    private var options: PerfHangMonitorOptions
    private let context: PerfMonitorContext
    private let trackerFactory: @Sendable (any PerfClock) -> MainThreadStateTracker

    private var tracker: MainThreadStateTracker?
    private var watchdogToken: PerfCadenceToken?
    private var queueProbeToken: PerfCadenceToken?

    /// 当前这次卡顿已经上报到哪一级，避免每个检查周期都重复上报同一次卡顿。
    private var reportedStage: PerfHangStage?
    /// 当前这次卡顿对应的唤醒序号。序号变了说明是新的一次卡顿。
    private var trackedWakeupCount: UInt64?
    /// 连续多少次采样的寄存器没变。
    private var unchangedRegisterSamples = 0
    private var lastRegisters: PerfRegisters?
    private var deadlockReported = false

    public init(options: PerfHangMonitorOptions, context: PerfMonitorContext) {
        self.init(options: options, context: context) { clock in
            MainThreadStateTracker(clock: clock)
        }
    }

    /// 注入自定义的忙闲追踪器。
    ///
    /// 测试用它换上「不挂真实 RunLoop observer」的追踪器，改由 `simulate*` 驱动。
    /// 被测的仍是同一份忙闲判定与卡顿升级逻辑。
    init(
        options: PerfHangMonitorOptions,
        context: PerfMonitorContext,
        trackerFactory: @escaping @Sendable (any PerfClock) -> MainThreadStateTracker
    ) {
        self.options = options
        self.context = context.scoped(to: Self.descriptor.id)
        self.trackerFactory = trackerFactory
    }

    /// 当前的追踪器，供测试驱动。
    var currentTracker: MainThreadStateTracker? { tracker }

    public func start() async throws {
        guard tracker == nil else { return }

        let tracker = trackerFactory(context.clock)
        self.tracker = tracker

        let recorder = context.recorder
        let options = options

        tracker.install(tracksPhases: options.tracksRunLoopPhases) { result in
            // 在主线程上执行。只做阈值比较和 O(1) 的环形缓冲入队。
            let totalMs = Double(result.totalNanos) / 1_000_000

            if result.totalNanos >= options.hitchThreshold.nanoseconds {
                recorder.record(
                    PerfHitchEvent(durationMs: totalMs, runLoopMode: result.mode),
                    severity: result.totalNanos >= options.unresponsiveThreshold.nanoseconds
                        ? .error
                        : .warning,
                    thread: .main
                )
            }

            if options.tracksRunLoopPhases,
               result.totalNanos >= options.phaseRecordingThreshold.nanoseconds {
                recorder.record(
                    PerfRunLoopPhaseSample(
                        timersMs: Double(result.timersNanos) / 1_000_000,
                        sourcesMs: Double(result.sourcesNanos) / 1_000_000,
                        totalMs: totalMs
                    ),
                    severity: .debug,
                    thread: .main
                )
            }
        }

        watchdogToken = context.scheduler.schedule(
            label: "\(Self.descriptor.id).watchdog",
            interval: options.checkInterval
        ) { [weak self] tick in
            await self?.checkMainThread(at: tick)
        }

        if options.tracksQueueLatency {
            queueProbeToken = context.scheduler.schedule(
                label: "\(Self.descriptor.id).queue-latency",
                interval: options.queueLatencyProbeInterval
            ) { [weak self] _ in
                await self?.probeQueueLatency()
            }
        }
    }

    public func stop() async {
        tracker?.removeObserver()
        tracker = nil

        for token in [watchdogToken, queueProbeToken].compactMap({ $0 }) {
            context.scheduler.cancel(token)
        }
        watchdogToken = nil
        queueProbeToken = nil

        resetHangState()
    }

    public func apply(_ options: PerfHangMonitorOptions) async {
        self.options = options
    }

    // MARK: - watchdog

    /// 在后台线程上执行。主线程卡死时这里照常运行——这正是它能抓到现场的原因。
    func checkMainThread(at tick: PerfTick) {
        guard let tracker else { return }
        let snapshot = tracker.snapshot()

        // 主线程正在休眠：上一次卡顿（如果有）已经结束
        guard let busySince = snapshot.busySinceUptime else {
            resetHangState()
            return
        }

        // 唤醒序号变了说明这是新的一次工作，之前的上报状态不再适用
        if trackedWakeupCount != snapshot.wakeupCount {
            resetHangState()
            trackedWakeupCount = snapshot.wakeupCount
        }

        let busyNanos = tick.uptimeNanos > busySince ? tick.uptimeNanos - busySince : 0
        guard busyNanos >= options.unresponsiveThreshold.nanoseconds else { return }

        let stage: PerfHangStage = busyNanos >= options.severeThreshold.nanoseconds
            ? .severe
            : .unresponsive

        trackDeadlockSignals(busyNanos: busyNanos, tick: tick)

        // 每个级别只报一次。不加这个判断的话，一次 10 秒的卡顿
        // 会在 250ms 的检查周期下产生 40 条重复记录，把缓冲冲垮。
        guard reportedStage != stage, reportedStage != .severe else { return }
        reportedStage = stage

        let snapshotStack = options.capturesStackOnHang ? captureMainThreadStack() : nil

        context.recorder.record(
            PerfHangEvent(
                stage: stage,
                durationMs: Double(busyNanos) / 1_000_000,
                // 关键：卡顿**还在进行中**就上报了，所以这份堆栈是真正的现场
                isOngoing: true,
                mainThreadStack: snapshotStack,
                stackSignature: snapshotStack?.signature
            ),
            severity: stage == .severe ? .critical : .error,
            thread: .main,
            // 时间戳用卡顿**开始**的时刻，不是发现它的时刻。
            // 否则时间线上会出现「事件发生在 T+2s」的错位，
            // 与同期的 CPU/内存采样对不上。
            timestamp: tick.date.addingTimeInterval(-Double(busyNanos) / 1_000_000_000),
            uptimeNanos: busySince
        )
    }

    /// 靠寄存器是否变化区分「卡死」与「跑得慢」。
    private func trackDeadlockSignals(busyNanos: UInt64, tick: PerfTick) {
        guard let backtrace = context.backtrace,
              let snapshot = try? backtrace.snapshotMainThread()
        else { return }

        defer { lastRegisters = snapshot.registers }

        guard let previous = lastRegisters, previous == snapshot.registers else {
            unchangedRegisterSamples = 0
            return
        }
        unchangedRegisterSamples += 1

        guard !deadlockReported,
              unchangedRegisterSamples >= options.deadlockUnchangedSampleCount
        else { return }
        deadlockReported = true

        context.recorder.record(
            PerfDeadlockEvent(
                durationMs: Double(busyNanos) / 1_000_000,
                unchangedSampleCount: unchangedRegisterSamples,
                registers: snapshot.registers,
                mainThreadStack: truncated(snapshot),
                // 死锁必然涉及至少两方：只看主线程只知道它在等锁，
                // 不知道锁被谁持有
                allThreadStacks: options.capturesAllThreadsOnDeadlock
                    ? (try? backtrace.snapshotAllThreads())?.map(truncated)
                    : nil
            ),
            severity: .critical,
            thread: .main,
            timestamp: tick.date,
            uptimeNanos: tick.uptimeNanos
        )
    }

    private func resetHangState() {
        reportedStage = nil
        trackedWakeupCount = nil
        unchangedRegisterSamples = 0
        lastRegisters = nil
        deadlockReported = false
    }

    private func captureMainThreadStack() -> PerfThreadSnapshot? {
        guard let backtrace = context.backtrace,
              let snapshot = try? backtrace.snapshotMainThread()
        else { return nil }
        return truncated(snapshot)
    }

    /// 截断过长的堆栈。
    ///
    /// 128 帧的完整栈编码成 JSON 可以到几十 KB，而定位问题几乎只靠栈顶几十帧。
    private func truncated(_ snapshot: PerfThreadSnapshot) -> PerfThreadSnapshot {
        guard snapshot.frames.count > options.maxStackFrames else { return snapshot }
        return PerfThreadSnapshot(
            thread: snapshot.thread,
            frames: Array(snapshot.frames.prefix(options.maxStackFrames)),
            registers: snapshot.registers,
            isTruncated: true,
            // 签名仍按完整帧列表计算，保证截断不影响聚合
            signature: snapshot.signature
        )
    }

    // MARK: - 主队列排队时延

    private func probeQueueLatency() async {
        let clock = context.clock
        let recorder = context.recorder
        let threshold = options.queueLatencyThreshold

        let enqueuedAt = clock.uptimeNanos
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let latency = clock.uptimeNanos > enqueuedAt ? clock.uptimeNanos - enqueuedAt : 0
                if latency >= threshold.nanoseconds {
                    recorder.record(
                        PerfQueueLatencySample(latencyMs: Double(latency) / 1_000_000),
                        severity: latency >= threshold.nanoseconds * 10 ? .error : .warning,
                        thread: .main
                    )
                }
                continuation.resume()
            }
        }
    }
}
