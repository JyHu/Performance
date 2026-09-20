import Foundation
import PerformanceBacktrace
import PerformanceCore

// MARK: - 载荷

/// 一个统计窗口内的热点方法。
public struct PerfHotspotSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "profiler.hotspot"

    /// 窗口内成功采到的样本数。
    public let sampleCount: Int
    public let windowMs: Double
    /// 出现频次最高的若干调用栈。
    public let topStacks: [PerfHotStack]
    /// 采样失败的次数（线程已退出、挂起失败等）。
    ///
    /// 失败率高说明数据不可信，必须能看见，
    /// 否则「Top1 占 80%」可能只是因为总共才采到 5 个样本。
    public let failedSampleCount: Int

    public init(sampleCount: Int, windowMs: Double, topStacks: [PerfHotStack], failedSampleCount: Int) {
        self.sampleCount = sampleCount
        self.windowMs = windowMs
        self.topStacks = topStacks
        self.failedSampleCount = failedSampleCount
    }
}

/// 一个高频出现的调用栈。
public struct PerfHotStack: Codable, Sendable, Equatable {
    /// 栈签名，用于跨窗口、跨设备聚合。
    public let signature: UInt64
    /// 本窗口内出现次数。
    public let occurrences: Int
    /// 占本窗口样本数的比例。
    public let share: Double
    /// 代表性的调用栈（取首次采到的那份）。
    public let frames: [PerfFrame]

    public init(signature: UInt64, occurrences: Int, share: Double, frames: [PerfFrame]) {
        self.signature = signature
        self.occurrences = occurrences
        self.share = share
        self.frames = frames
    }
}

// MARK: - 监测器

public struct PerfProfilerMonitorOptions: PerfMonitorOptions {
    /// 采样间隔。
    ///
    /// 10ms 是精度与开销的折中。间隔越短越能抓到短促的热点，
    /// 但每次采样都要挂起目标线程，过密会实质影响被观测线程的性能。
    public var samplingInterval: PerfDuration = .milliseconds(10)

    /// 聚合窗口。
    public var windowInterval: PerfDuration = .seconds(10)

    /// 每个窗口上报前几名。
    public var topStackCount: Int = 5

    /// 代表性调用栈保留多少帧。
    public var maxFramesPerStack: Int = 32

    /// 占比低于此值的栈不上报——低频栈多半是噪声。
    public var minimumShare: Double = 0.05

    /// 是否只采主线程。
    ///
    /// 默认只采主线程：绝大多数用户可感知的性能问题都出在主线程上，
    /// 而全线程采样的开销和数据量都要高一个量级。
    public var mainThreadOnly: Bool = true

    public init() {}
}

/// 热点方法采样。
///
/// ## 采样必须由独立线程挂起目标线程来取栈
///
/// 上一版用 `DispatchQueue.main.async { Thread.callStackSymbols }` 采样：
/// 主线程一旦真的忙起来，这个 block 就排不上队，于是「热点采样器」
/// 只在主线程**空闲**时才采得到样本。想测热点，测到的全是空闲——
/// 这个模块从设计上就不可能产出有用数据。
public actor PerfProfilerMonitor: PerfMonitor {
    public nonisolated static let descriptor = PerfMonitorDescriptor(
        id: PerfProfiler.monitorID,
        displayName: "热点采样",
        kinds: [PerfHotspotSample.kind],
        platforms: .all
    )

    private var options: PerfProfilerMonitorOptions
    private let context: PerfMonitorContext

    private var samplerToken: PerfCadenceToken?
    private var windowToken: PerfCadenceToken?
    private var aggregator: HotspotAggregator?

    public init(options: PerfProfilerMonitorOptions, context: PerfMonitorContext) {
        self.options = options
        self.context = context.scoped(to: Self.descriptor.id)
    }

    public func start() async throws {
        guard samplerToken == nil else { return }
        guard let backtrace = context.backtrace else {
            context.log.warning("未链接 PerfBacktrace，热点采样不可用")
            return
        }

        let aggregator = HotspotAggregator(maxFramesPerStack: options.maxFramesPerStack)
        self.aggregator = aggregator

        let mainThreadOnly = options.mainThreadOnly

        samplerToken = context.scheduler.schedule(
            label: "\(Self.descriptor.id).sample",
            interval: options.samplingInterval
        ) { _ in
            // 跑在调度器的后台任务里，与被观测线程完全独立。
            // 主线程卡死时这里照常采样——这正是它能抓到热点的原因。
            do {
                if mainThreadOnly {
                    aggregator.add(try backtrace.snapshotMainThread())
                } else {
                    for snapshot in try backtrace.snapshotAllThreads() {
                        aggregator.add(snapshot)
                    }
                }
            } catch {
                aggregator.recordFailure()
            }
        }

        windowToken = context.scheduler.schedule(
            label: "\(Self.descriptor.id).window",
            interval: options.windowInterval
        ) { [weak self] tick in
            await self?.emitWindow(at: tick)
        }
    }

    public func stop() async {
        for token in [samplerToken, windowToken].compactMap({ $0 }) {
            context.scheduler.cancel(token)
        }
        samplerToken = nil
        windowToken = nil
        aggregator = nil
    }

    public func apply(_ options: PerfProfilerMonitorOptions) async {
        self.options = options
    }

    func emitWindow(at tick: PerfTick) {
        guard let window = aggregator?.drain() else { return }
        guard window.sampleCount > 0 || window.failureCount > 0 else { return }

        let total = Double(max(window.sampleCount, 1))
        let top = window.stacks
            .sorted { $0.occurrences > $1.occurrences }
            .prefix(options.topStackCount)
            .map {
                PerfHotStack(
                    signature: $0.signature,
                    occurrences: $0.occurrences,
                    share: Double($0.occurrences) / total,
                    frames: $0.frames
                )
            }
            .filter { $0.share >= options.minimumShare }

        context.recorder.record(
            PerfHotspotSample(
                sampleCount: window.sampleCount,
                windowMs: options.windowInterval.milliseconds,
                topStacks: Array(top),
                failedSampleCount: window.failureCount
            ),
            // 热点本身不是「问题」，是排查材料。定级为 debug，
            // 生产环境可以通过 minimumSeverity 整体过滤掉。
            severity: .debug,
            thread: options.mainThreadOnly ? .main : nil,
            timestamp: tick.date,
            uptimeNanos: tick.uptimeNanos
        )
    }
}

// MARK: - 聚合

/// 按栈签名聚合采样结果。
///
/// 采样发生在调度器的后台任务里，聚合窗口由另一个任务触发，因此需要同步。
final class HotspotAggregator: @unchecked Sendable {
    struct Entry {
        let signature: UInt64
        var occurrences: Int
        /// 代表性调用栈，取首次采到的那份。
        let frames: [PerfFrame]
    }

    struct Window {
        let sampleCount: Int
        let failureCount: Int
        let stacks: [Entry]
    }

    private let lock = PerfLock()
    private let maxFramesPerStack: Int
    private var entries: [UInt64: Entry] = [:]
    private var sampleCount = 0
    private var failureCount = 0

    init(maxFramesPerStack: Int) {
        self.maxFramesPerStack = maxFramesPerStack
    }

    func add(_ snapshot: PerfThreadSnapshot) {
        lock.lock()
        defer { lock.unlock() }

        sampleCount += 1
        if entries[snapshot.signature] != nil {
            entries[snapshot.signature]?.occurrences += 1
        } else {
            entries[snapshot.signature] = Entry(
                signature: snapshot.signature,
                occurrences: 1,
                frames: Array(snapshot.frames.prefix(maxFramesPerStack))
            )
        }
    }

    func recordFailure() {
        lock.withLock { failureCount += 1 }
    }

    func drain() -> Window {
        lock.lock()
        defer { lock.unlock() }

        let window = Window(
            sampleCount: sampleCount,
            failureCount: failureCount,
            stacks: Array(entries.values)
        )
        entries.removeAll(keepingCapacity: true)
        sampleCount = 0
        failureCount = 0
        return window
    }
}
