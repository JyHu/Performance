import Foundation
import PerformanceCore

#if canImport(MetricKit)
import MetricKit
#endif

// MARK: - 载荷

/// 系统投递的聚合性能指标。
public struct PerfMetricKitPayload: PerfPayload, Equatable {
    public static let kind: PerfKind = "metrickit.payload"

    /// 数据覆盖的时间范围。
    ///
    /// MetricKit 的数据**最长滞后 24 小时**，且是整段时间的聚合值。
    /// 不带上这个范围就无法把它与自采的实时数据对齐——
    /// 那会让人误以为今天的系统指标反映的是今天的代码。
    public let beginDate: Date
    public let endDate: Date

    /// 系统测得的启动耗时（毫秒），取自 `MXAppLaunchMetric` 的中位数。
    public let launchTimeMedianMs: Double?
    /// 系统测得的挂起时长中位数（毫秒）。
    public let resumeTimeMedianMs: Double?
    /// 前台卡顿时长（毫秒）。
    public let hangTimeMs: Double?
    /// 前台 CPU 时间（秒）。
    public let cumulativeCPUSeconds: Double?
    /// 峰值内存（MB）。
    public let peakMemoryMB: Double?
    /// 逻辑写入量（MB）。
    ///
    /// 在 iOS 上这是**唯一**能拿到的磁盘写入量指标——
    /// `proc_pid_rusage` 在 iOS SDK 里没有公开声明。
    public let logicalWritesMB: Double?
    /// 原始 JSON，保留全部细节。
    public let rawJSON: String?

    public init(
        beginDate: Date,
        endDate: Date,
        launchTimeMedianMs: Double?,
        resumeTimeMedianMs: Double?,
        hangTimeMs: Double?,
        cumulativeCPUSeconds: Double?,
        peakMemoryMB: Double?,
        logicalWritesMB: Double?,
        rawJSON: String?
    ) {
        self.beginDate = beginDate
        self.endDate = endDate
        self.launchTimeMedianMs = launchTimeMedianMs
        self.resumeTimeMedianMs = resumeTimeMedianMs
        self.hangTimeMs = hangTimeMs
        self.cumulativeCPUSeconds = cumulativeCPUSeconds
        self.peakMemoryMB = peakMemoryMB
        self.logicalWritesMB = logicalWritesMB
        self.rawJSON = rawJSON
    }
}

/// 系统投递的诊断（崩溃、卡顿、磁盘写入异常等）。
public struct PerfMetricKitDiagnostic: PerfPayload, Equatable {
    public static let kind: PerfKind = "metrickit.diagnostic"

    public let category: Category
    public let beginDate: Date
    public let endDate: Date
    /// 诊断详情的 JSON，含系统已符号化的调用树。
    ///
    /// 系统侧符号化是 MetricKit 相对自采崩溃捕获的一大优势：
    /// 不需要上传 dSYM，也不需要自己做符号还原。
    public let rawJSON: String?

    public enum Category: String, Codable, Sendable {
        case crash, hang, diskWriteException, cpuException, appLaunch
    }

    public init(category: Category, beginDate: Date, endDate: Date, rawJSON: String?) {
        self.category = category
        self.beginDate = beginDate
        self.endDate = endDate
        self.rawJSON = rawJSON
    }
}

// MARK: - 监测器

public struct PerfMetricKitMonitorOptions: PerfMonitorOptions {
    /// 是否保留原始 JSON。
    ///
    /// 原始数据可能有几十 KB，但里面含系统符号化后的调用树，
    /// 是这条链路最有价值的部分，默认保留。
    public var keepsRawPayload: Bool = true

    /// 是否接收诊断（崩溃 / 卡顿 / 磁盘异常）。
    public var receivesDiagnostics: Bool = true

    public init() {}
}

/// MetricKit 桥接。
///
/// ## 与自采数据的关系是互补，不是替代
///
/// MetricKit 的优势：系统视角、零运行时开销、崩溃栈已符号化、
/// 覆盖全体用户而非只有装了监控的那部分。
///
/// 它的局限同样明确：**最长滞后 24 小时**、只有聚合值没有单次事件、
/// 拿不到任何业务上下文（不知道用户当时在哪个页面做什么）。
///
/// 所以两条链路都要有：MetricKit 给出可信的大盘基线，
/// 自采数据用来定位具体问题。
public actor PerfMetricKitMonitor: PerfMonitor {
    public nonisolated static let descriptor = PerfMonitorDescriptor(
        id: PerfMetricKit.monitorID,
        displayName: "MetricKit",
        kinds: [PerfMetricKitPayload.kind, PerfMetricKitDiagnostic.kind],
        // macOS 上 MetricKit 自 12.0 起可用，但只在部分场景投递数据
        platforms: .all
    )

    private var options: PerfMetricKitMonitorOptions
    private let context: PerfMonitorContext

    #if canImport(MetricKit) && os(iOS)
    private var subscriber: MetricKitSubscriber?
    #endif

    public init(options: PerfMetricKitMonitorOptions, context: PerfMonitorContext) {
        self.options = options
        self.context = context.scoped(to: Self.descriptor.id)
    }

    public func start() async throws {
        #if canImport(MetricKit) && os(iOS)
        guard subscriber == nil else { return }

        let subscriber = MetricKitSubscriber(
            recorder: context.recorder,
            options: options,
            log: context.log
        )
        self.subscriber = subscriber
        await MainActor.run {
            MXMetricManager.shared.add(subscriber)
        }
        context.log.info("已订阅 MetricKit；数据由系统每日投递一次，最长滞后 24 小时")
        #else
        context.log.info("当前平台不提供 MetricKit 数据投递，该监测器空转")
        #endif
    }

    public func stop() async {
        #if canImport(MetricKit) && os(iOS)
        guard let subscriber else { return }
        await MainActor.run {
            MXMetricManager.shared.remove(subscriber)
        }
        self.subscriber = nil
        #endif
    }

    public func apply(_ options: PerfMetricKitMonitorOptions) async {
        self.options = options
    }
}

// MARK: - 订阅者

#if canImport(MetricKit) && os(iOS)

/// `@unchecked Sendable`：全部存储属性都是不可变的 `let`，且本身都是 `Sendable`
/// （`PerfRecorder`、`PerfMetricKitMonitorOptions`、`PerfLog`），构造后没有任何可变状态。
/// 需要显式标注是因为它要从 actor 交给 main-actor 隔离的 `MXMetricManager`。
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let recorder: PerfRecorder
    private let options: PerfMetricKitMonitorOptions
    private let log: PerfLog

    init(recorder: PerfRecorder, options: PerfMetricKitMonitorOptions, log: PerfLog) {
        self.recorder = recorder
        self.options = options
        self.log = log
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            recorder.record(
                PerfMetricKitPayload(
                    beginDate: payload.timeStampBegin,
                    endDate: payload.timeStampEnd,
                    launchTimeMedianMs: payload.applicationLaunchMetrics
                        .flatMap { histogramMedian($0.histogrammedTimeToFirstDraw) },
                    resumeTimeMedianMs: payload.applicationLaunchMetrics
                        .flatMap { histogramMedian($0.histogrammedApplicationResumeTime) },
                    hangTimeMs: payload.applicationResponsivenessMetrics
                        .flatMap { histogramMedian($0.histogrammedApplicationHangTime) },
                    cumulativeCPUSeconds: payload.cpuMetrics?
                        .cumulativeCPUTime.converted(to: .seconds).value,
                    peakMemoryMB: payload.memoryMetrics?
                        .peakMemoryUsage.converted(to: .megabytes).value,
                    logicalWritesMB: payload.diskIOMetrics?
                        .cumulativeLogicalWrites.converted(to: .megabytes).value,
                    rawJSON: options.keepsRawPayload
                        ? String(decoding: payload.jsonRepresentation(), as: UTF8.self)
                        : nil
                ),
                severity: .info,
                // 时间戳取数据覆盖区间的**开始**，不是收到的时刻——
                // 否则这批数据会被放到时间线上错误的位置（最多错 24 小时）
                timestamp: payload.timeStampBegin,
                uptimeNanos: recorder.clock.uptimeNanos
            )
        }
        log.info("收到 \(payloads.count) 份 MetricKit 指标")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard options.receivesDiagnostics else { return }

        for payload in payloads {
            emit(payload.crashDiagnostics, .crash, payload)
            emit(payload.hangDiagnostics, .hang, payload)
            emit(payload.diskWriteExceptionDiagnostics, .diskWriteException, payload)
            emit(payload.cpuExceptionDiagnostics, .cpuException, payload)
        }
    }

    private func emit(
        _ diagnostics: [MXDiagnostic]?,
        _ category: PerfMetricKitDiagnostic.Category,
        _ payload: MXDiagnosticPayload
    ) {
        guard let diagnostics, !diagnostics.isEmpty else { return }

        for diagnostic in diagnostics {
            recorder.record(
                PerfMetricKitDiagnostic(
                    category: category,
                    beginDate: payload.timeStampBegin,
                    endDate: payload.timeStampEnd,
                    rawJSON: options.keepsRawPayload
                        ? String(decoding: diagnostic.jsonRepresentation(), as: UTF8.self)
                        : nil
                ),
                severity: category == .crash ? .critical : .error,
                timestamp: payload.timeStampBegin,
                uptimeNanos: recorder.clock.uptimeNanos
            )
        }
    }
}

/// 直方图的中位数。
///
/// MetricKit 给的是分桶直方图而非原始值，只能按累计计数定位中位数所在的桶，
/// 取桶的上界作为近似。精度受分桶粒度限制，这是这个 API 的固有限制。
///
/// 写成自由函数而非 `MXHistogram` 的扩展：`MXHistogram` 是泛型 Objective-C 类，
/// 它的扩展在运行时拿不到泛型参数，无法用 `MXHistogramBucket<UnitType>` 做转换。
private func histogramMedian<T: Unit>(_ histogram: MXHistogram<T>) -> Double? {
    let buckets = histogram.bucketEnumerator.compactMap { $0 as? MXHistogramBucket<T> }
    guard !buckets.isEmpty else { return nil }

    let total = buckets.reduce(0) { $0 + $1.bucketCount }
    guard total > 0 else { return nil }

    var cumulative = 0
    for bucket in buckets {
        cumulative += bucket.bucketCount
        if cumulative * 2 >= total {
            return bucket.bucketEnd.value
        }
    }
    return buckets.last?.bucketEnd.value
}

#endif
