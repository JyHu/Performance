import Foundation
import PerformanceCore
import PerformanceSystemKit

// MARK: - 载荷

/// 磁盘剩余空间。
public struct PerfDiskSpaceSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "disk.space"

    public let totalGB: Double
    /// 「重要用途」的可用容量。
    ///
    /// 这是系统给出的、计入可清理缓存后的真实可用量，
    /// 比裸的剩余字节数更贴近「还能写多少」。
    public let availableForImportantUsageGB: Double?
    public let availableGB: Double?

    public init(totalGB: Double, availableForImportantUsageGB: Double?, availableGB: Double?) {
        self.totalGB = totalGB
        self.availableForImportantUsageGB = availableForImportantUsageGB
        self.availableGB = availableGB
    }
}

/// 磁盘吞吐。
public struct PerfDiskThroughputSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "disk.throughput"

    public let readBytesPerSecond: Double
    public let writtenBytesPerSecond: Double
    public let windowMs: Double

    public init(readBytesPerSecond: Double, writtenBytesPerSecond: Double, windowMs: Double) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writtenBytesPerSecond = writtenBytesPerSecond
        self.windowMs = windowMs
    }
}

/// 主线程上的同步 I/O。
public struct PerfMainThreadIOEvent: PerfRedactablePayload, Equatable {
    public static let kind: PerfKind = "disk.main_thread_io"

    public let operation: String
    /// 目标路径（已脱敏）。
    public let path: String?
    public let durationMs: Double
    public let byteCount: Int?

    public init(operation: String, path: String?, durationMs: Double, byteCount: Int?) {
        self.operation = operation
        self.path = path
        self.durationMs = durationMs
        self.byteCount = byteCount
    }

    public func redacted(using policy: PerfRedactionPolicy) -> PerfMainThreadIOEvent {
        PerfMainThreadIOEvent(
            operation: operation,
            // 路径里常带用户名和容器 UUID，两者都能定位到具体设备与安装实例
            path: path.map(policy.redact(path:)),
            durationMs: durationMs,
            byteCount: byteCount
        )
    }
}

// MARK: - 主线程 I/O 探针

/// 业务方主动包裹 I/O 操作的探针。
///
/// ## 它的定位：补充而非替代
///
/// 真正的磁盘吞吐来自内核（`PerfDiskMetrics.processIO`），那是全量的。
/// 这个探针只解决内核数据回答不了的问题：**是谁、在哪一行、
/// 在主线程上做了同步 I/O**。
///
/// 上一版把手动埋点当成了 I/O 监控的**全部**——业务方任何一处直接用
/// `Data(contentsOf:)`、`FileHandle`、SQLite，都完全不在统计范围内，
/// 于是磁盘再忙，数据看起来也是零。
public enum PerfIOProbe {
    /// 包裹一次 I/O 操作。只有发生在主线程且超过阈值时才记录。
    @discardableResult
    public static func measure<T>(
        _ operation: String,
        path: String? = nil,
        byteCount: Int? = nil,
        body: () throws -> T
    ) rethrows -> T {
        guard let reporter = storage.reporter else { return try body() }

        let start = reporter.clock.uptimeNanos
        defer {
            reporter.report(
                operation: operation,
                path: path,
                durationNanos: reporter.clock.uptimeNanos - start,
                byteCount: byteCount,
                isMainThread: Thread.isMainThread
            )
        }
        return try body()
    }

    static func install(_ reporter: IOReporter?) {
        storage.reporter = reporter
    }

    private static let storage = ReporterStorage()

    private final class ReporterStorage: @unchecked Sendable {
        private let lock = PerfLock()
        private var value: IOReporter?
        var reporter: IOReporter? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}

struct IOReporter: Sendable {
    let recorder: PerfRecorder
    let clock: any PerfClock
    let mainThreadThreshold: PerfDuration

    func report(
        operation: String,
        path: String?,
        durationNanos: UInt64,
        byteCount: Int?,
        isMainThread: Bool
    ) {
        // 后台线程上的 I/O 耗时长是正常的，不值得记录；
        // 主线程上超过阈值才是问题
        guard isMainThread, durationNanos >= mainThreadThreshold.nanoseconds else { return }

        recorder.record(
            PerfMainThreadIOEvent(
                operation: operation,
                path: path,
                durationMs: Double(durationNanos) / 1_000_000,
                byteCount: byteCount
            ),
            severity: durationNanos >= mainThreadThreshold.nanoseconds * 10 ? .error : .warning,
            thread: .main
        )
    }
}

// MARK: - 监测器

public struct PerfDiskMonitorOptions: PerfMonitorOptions {
    /// 剩余空间采样周期。空间变化很慢，不需要采得密。
    public var spaceInterval: PerfDuration = .minutes(5)

    /// 吞吐采样周期。
    public var throughputInterval: PerfDuration = .seconds(10)

    /// 主线程同步 I/O 超过此值才记录。
    ///
    /// 8ms 约等于一帧的预算，超过就意味着这次 I/O 至少吃掉了一帧。
    public var mainThreadIOThreshold: PerfDuration = .milliseconds(8)

    /// 剩余空间低于此值时告警。
    public var lowSpaceWarningGB: Double = 1.0

    public init() {}
}

/// 磁盘监测。
public actor PerfDiskMonitor: PerfMonitor {
    public nonisolated static let descriptor = PerfMonitorDescriptor(
        id: PerfDisk.monitorID,
        displayName: "磁盘",
        kinds: [
            PerfDiskSpaceSample.kind,
            PerfDiskThroughputSample.kind,
            PerfMainThreadIOEvent.kind,
        ],
        platforms: .all
    )

    private var options: PerfDiskMonitorOptions
    private let context: PerfMonitorContext

    private var spaceToken: PerfCadenceToken?
    private var throughputToken: PerfCadenceToken?
    private var previousIO: PerfDiskIO?
    private var previousIOSampleUptime: UInt64?

    public init(options: PerfDiskMonitorOptions, context: PerfMonitorContext) {
        self.options = options
        self.context = context.scoped(to: Self.descriptor.id)
    }

    public func start() async throws {
        guard spaceToken == nil else { return }

        PerfIOProbe.install(
            IOReporter(
                recorder: context.recorder,
                clock: context.clock,
                mainThreadThreshold: options.mainThreadIOThreshold
            )
        )

        spaceToken = context.scheduler.schedule(
            label: "\(Self.descriptor.id).space",
            interval: options.spaceInterval
        ) { [weak self] tick in
            await self?.sampleSpace(at: tick)
        }

        // iOS 上拿不到内核级 I/O 计量，注册了也只会空转，
        // 不如直接不注册并说明原因
        if PerfDiskMetrics.processIO() != nil {
            previousIO = PerfDiskMetrics.processIO()
            previousIOSampleUptime = context.clock.uptimeNanos
            throughputToken = context.scheduler.schedule(
                label: "\(Self.descriptor.id).throughput",
                interval: options.throughputInterval
            ) { [weak self] tick in
                await self?.sampleThroughput(at: tick)
            }
        } else {
            context.log.info("当前平台没有公开 API 可取进程磁盘 I/O，吞吐统计不可用；请改用 MetricKit 的磁盘指标")
        }
    }

    public func stop() async {
        PerfIOProbe.install(nil)
        for token in [spaceToken, throughputToken].compactMap({ $0 }) {
            context.scheduler.cancel(token)
        }
        spaceToken = nil
        throughputToken = nil
    }

    public func apply(_ options: PerfDiskMonitorOptions) async {
        self.options = options
    }

    private func sampleSpace(at tick: PerfTick) {
        guard let capacity = PerfDiskMetrics.volumeCapacity() else { return }

        let gb = { (bytes: UInt64) in Double(bytes) / 1_073_741_824 }
        let availableGB = capacity.availableForImportantUsageBytes.map(gb)
            ?? capacity.availableBytes.map(gb)

        context.recorder.record(
            PerfDiskSpaceSample(
                totalGB: gb(capacity.totalBytes),
                availableForImportantUsageGB: capacity.availableForImportantUsageBytes.map(gb),
                availableGB: capacity.availableBytes.map(gb)
            ),
            severity: (availableGB ?? .infinity) < options.lowSpaceWarningGB ? .warning : .info,
            timestamp: tick.date,
            uptimeNanos: tick.uptimeNanos
        )
    }

    private func sampleThroughput(at tick: PerfTick) {
        guard let current = PerfDiskMetrics.processIO() else { return }
        defer {
            previousIO = current
            previousIOSampleUptime = tick.uptimeNanos
        }
        guard let previous = previousIO, let previousUptime = previousIOSampleUptime else { return }

        let window = PerfDuration(
            nanoseconds: tick.uptimeNanos > previousUptime ? tick.uptimeNanos - previousUptime : 0
        )
        guard window.nanoseconds > 0 else { return }

        let throughput = current.throughput(since: previous, elapsed: window)
        context.recorder.record(
            PerfDiskThroughputSample(
                readBytesPerSecond: throughput.read,
                writtenBytesPerSecond: throughput.written,
                windowMs: window.milliseconds
            ),
            severity: .debug,
            timestamp: tick.date,
            uptimeNanos: tick.uptimeNanos
        )
    }
}
