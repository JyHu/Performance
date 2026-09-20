import Foundation
import PerformanceCore

// MARK: - 载荷

/// 一次网络请求的耗时分解。
public struct PerfNetworkRequestSample: PerfRedactablePayload, Equatable {
    public static let kind: PerfKind = "network.request"

    /// 请求 URL（已脱敏）。
    public let url: String
    public let method: String?
    public let statusCode: Int?

    /// 各阶段耗时（毫秒）。取不到的阶段为 nil。
    ///
    /// 分阶段而不是只记总耗时，是因为优化方向完全不同：
    /// DNS 慢要查解析配置，TLS 慢要看握手与证书链，
    /// TTFB 慢是服务端问题，传输慢才是带宽或响应体大小的问题。
    public let dnsMs: Double?
    public let connectMs: Double?
    public let tlsMs: Double?
    /// 首字节时间。
    public let ttfbMs: Double?
    public let totalMs: Double

    public let requestBytes: Int64?
    public let responseBytes: Int64?
    /// 是否命中本地缓存。
    ///
    /// 缓存命中的请求耗时极短，混在一起统计会把平均值拉得很好看，
    /// 掩盖真实的网络状况。
    public let isCacheHit: Bool
    /// 连接是否被复用。
    public let isReusedConnection: Bool

    public init(
        url: String,
        method: String?,
        statusCode: Int?,
        dnsMs: Double?,
        connectMs: Double?,
        tlsMs: Double?,
        ttfbMs: Double?,
        totalMs: Double,
        requestBytes: Int64?,
        responseBytes: Int64?,
        isCacheHit: Bool,
        isReusedConnection: Bool
    ) {
        self.url = url
        self.method = method
        self.statusCode = statusCode
        self.dnsMs = dnsMs
        self.connectMs = connectMs
        self.tlsMs = tlsMs
        self.ttfbMs = ttfbMs
        self.totalMs = totalMs
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.isCacheHit = isCacheHit
        self.isReusedConnection = isReusedConnection
    }

    public func redacted(using policy: PerfRedactionPolicy) -> PerfNetworkRequestSample {
        PerfNetworkRequestSample(
            // URL 的 query 里常带 token、签名、用户标识
            url: policy.redact(urlString: url),
            method: method,
            statusCode: statusCode,
            dnsMs: dnsMs,
            connectMs: connectMs,
            tlsMs: tlsMs,
            ttfbMs: ttfbMs,
            totalMs: totalMs,
            requestBytes: requestBytes,
            responseBytes: responseBytes,
            isCacheHit: isCacheHit,
            isReusedConnection: isReusedConnection
        )
    }
}

/// 一次网络失败。
public struct PerfNetworkFailureSample: PerfRedactablePayload, Equatable {
    public static let kind: PerfKind = "network.failure"

    public let url: String
    public let errorDomain: String
    public let errorCode: Int
    public let isTimeout: Bool
    public let elapsedMs: Double

    public init(url: String, errorDomain: String, errorCode: Int, isTimeout: Bool, elapsedMs: Double) {
        self.url = url
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.isTimeout = isTimeout
        self.elapsedMs = elapsedMs
    }

    public func redacted(using policy: PerfRedactionPolicy) -> PerfNetworkFailureSample {
        PerfNetworkFailureSample(
            url: policy.redact(urlString: url),
            errorDomain: errorDomain,
            errorCode: errorCode,
            isTimeout: isTimeout,
            elapsedMs: elapsedMs
        )
    }
}

/// 滑动窗口内的成功率与超时率。
public struct PerfNetworkHealthSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "network.timeout_rate"

    public let totalRequests: Int
    public let failureCount: Int
    public let timeoutCount: Int
    public let timeoutRate: Double
    public let medianTotalMs: Double?
    /// P95 耗时。
    ///
    /// 平均值会被大量快请求稀释；真正影响体感的是尾部延迟。
    public let p95TotalMs: Double?
    public let windowMs: Double

    public init(
        totalRequests: Int,
        failureCount: Int,
        timeoutCount: Int,
        timeoutRate: Double,
        medianTotalMs: Double?,
        p95TotalMs: Double?,
        windowMs: Double
    ) {
        self.totalRequests = totalRequests
        self.failureCount = failureCount
        self.timeoutCount = timeoutCount
        self.timeoutRate = timeoutRate
        self.medianTotalMs = medianTotalMs
        self.p95TotalMs = p95TotalMs
        self.windowMs = windowMs
    }
}

// MARK: - 观测入口

/// 网络观测的接入点。
///
/// ## 两种接入方式
///
/// 1. `makeSession(configuration:)` —— 拿一个已装好观测的 `URLSession`。
///    精确、零副作用，但要求业务方改用这个 session。
/// 2. `observe(metrics:task:)` —— 业务方在自己的
///    `URLSessionTaskDelegate.didFinishCollecting` 里转发一行。
///    适合已有大量 session 的工程。
///
/// 刻意**不**提供全局 `URLProtocol` 注入：那会改变所有请求的执行路径，
/// 可能影响上传、WebSocket、后台会话的行为——性能监控不该有这种侵入性。
public enum PerfNetworkObserver {
    /// 造一个装好观测的 session。
    ///
    /// 注意持有它并在用完后 `invalidateAndCancel()`。
    /// 上一版每次调用都 new 一个 delegate，而 `URLSession` 强持有 delegate
    /// 且全仓没有任何 invalidate 调用——每调一次泄漏一份。
    public static func makeSession(
        configuration: URLSessionConfiguration = .default,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: PerfNetworkSessionDelegate(),
            delegateQueue: delegateQueue
        )
    }

    /// 从业务方自己的 delegate 里转发指标。
    public static func observe(metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        storage.collector?.collect(metrics: metrics, task: task)
    }

    /// 转发一次失败。
    public static func observe(error: any Error, task: URLSessionTask, elapsed: PerfDuration) {
        storage.collector?.collect(error: error, task: task, elapsed: elapsed)
    }

    static func install(_ collector: NetworkCollector?) {
        storage.collector = collector
    }

    static var collector: NetworkCollector? { storage.collector }

    private static let storage = CollectorStorage()

    private final class CollectorStorage: @unchecked Sendable {
        private let lock = PerfLock()
        private var value: NetworkCollector?
        var collector: NetworkCollector? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}

/// 装在 `makeSession` 产出的 session 上的 delegate。
final class PerfNetworkSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        PerfNetworkObserver.observe(metrics: metrics, task: task)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        PerfNetworkObserver.observe(
            error: error,
            task: task,
            elapsed: .seconds(0)     // 精确耗时由 metrics 回调给出
        )
    }
}

// MARK: - 采集

/// 把 `URLSessionTaskMetrics` 转成记录，并维护滑动窗口统计。
final class NetworkCollector: @unchecked Sendable {
    private let recorder: PerfRecorder
    private let options: PerfNetworkMonitorOptions

    private let lock = PerfLock()
    private var windowTotals: [Double] = []
    private var windowFailures = 0
    private var windowTimeouts = 0

    init(recorder: PerfRecorder, options: PerfNetworkMonitorOptions) {
        self.recorder = recorder
        self.options = options
    }

    func collect(metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        guard let transaction = metrics.transactionMetrics.last else { return }

        let totalMs = metrics.taskInterval.duration * 1_000
        let url = task.originalRequest?.url?.absoluteString
            ?? transaction.request.url?.absoluteString
            ?? "<unknown>"

        // 缓存命中的请求耗时极短，混进统计会把百分位拉得很好看，掩盖真实网络状况
        let isCacheHit = transaction.resourceFetchType == .localCache

        lock.withLock {
            if !isCacheHit {
                windowTotals.append(totalMs)
            }
        }

        guard options.recordsIndividualRequests else { return }

        let sample = PerfNetworkRequestSample(
            url: url,
            method: transaction.request.httpMethod,
            statusCode: (transaction.response as? HTTPURLResponse)?.statusCode,
            dnsMs: Self.interval(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connectMs: Self.interval(transaction.connectStartDate, transaction.connectEndDate),
            tlsMs: Self.interval(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            ttfbMs: Self.interval(transaction.requestStartDate, transaction.responseStartDate),
            totalMs: totalMs,
            requestBytes: transaction.countOfRequestBodyBytesSent,
            responseBytes: transaction.countOfResponseBodyBytesReceived,
            isCacheHit: isCacheHit,
            isReusedConnection: transaction.isReusedConnection
        )

        recorder.record(
            sample,
            severity: severity(totalMs: totalMs, isCacheHit: isCacheHit),
            timestamp: metrics.taskInterval.start,
            uptimeNanos: recorder.clock.uptimeNanos
        )
    }

    func collect(error: any Error, task: URLSessionTask, elapsed: PerfDuration) {
        let nsError = error as NSError
        let isTimeout = nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorTimedOut

        lock.withLock {
            windowFailures += 1
            if isTimeout { windowTimeouts += 1 }
        }

        recorder.record(
            PerfNetworkFailureSample(
                url: task.originalRequest?.url?.absoluteString ?? "<unknown>",
                errorDomain: nsError.domain,
                errorCode: nsError.code,
                isTimeout: isTimeout,
                elapsedMs: elapsed.milliseconds
            ),
            severity: isTimeout ? .error : .warning
        )
    }

    /// 结算滑动窗口。
    func drainWindow(windowMs: Double) -> PerfNetworkHealthSample? {
        let (totals, failures, timeouts): ([Double], Int, Int) = lock.withLock {
            let result = (windowTotals, windowFailures, windowTimeouts)
            windowTotals.removeAll(keepingCapacity: true)
            windowFailures = 0
            windowTimeouts = 0
            return result
        }

        let total = totals.count + failures
        guard total > 0 else { return nil }

        let sorted = totals.sorted()
        return PerfNetworkHealthSample(
            totalRequests: total,
            failureCount: failures,
            timeoutCount: timeouts,
            timeoutRate: Double(timeouts) / Double(total),
            medianTotalMs: Self.percentile(sorted, 0.5),
            // 平均值会被大量快请求稀释，真正影响体感的是尾部
            p95TotalMs: Self.percentile(sorted, 0.95),
            windowMs: windowMs
        )
    }

    private func severity(totalMs: Double, isCacheHit: Bool) -> PerfSeverity {
        if isCacheHit { return .debug }
        if totalMs >= options.verySlowRequestThreshold.milliseconds { return .error }
        if totalMs >= options.slowRequestThreshold.milliseconds { return .warning }
        return .info
    }

    private static func interval(_ start: Date?, _ end: Date?) -> Double? {
        guard let start, let end, end >= start else { return nil }
        return end.timeIntervalSince(start) * 1_000
    }

    private static func percentile(_ sorted: [Double], _ q: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

// MARK: - 监测器

public struct PerfNetworkMonitorOptions: PerfMonitorOptions {
    /// 是否为每个请求单独记录。
    ///
    /// 关掉只保留窗口聚合。请求密集的 app 里逐条记录数据量很可观。
    public var recordsIndividualRequests: Bool = true

    public var slowRequestThreshold: PerfDuration = .seconds(1)
    public var verySlowRequestThreshold: PerfDuration = .seconds(5)

    /// 健康度统计窗口。
    public var healthWindowInterval: PerfDuration = .minutes(1)

    /// 超时率超过此值时告警。
    public var timeoutRateWarning: Double = 0.05

    public init() {}
}

/// 网络性能监测。
public actor PerfNetworkMonitor: PerfMonitor {
    public nonisolated static let descriptor = PerfMonitorDescriptor(
        id: PerfNetwork.monitorID,
        displayName: "网络",
        kinds: [
            PerfNetworkRequestSample.kind,
            PerfNetworkFailureSample.kind,
            PerfNetworkHealthSample.kind,
        ],
        platforms: .all
    )

    private var options: PerfNetworkMonitorOptions
    private let context: PerfMonitorContext
    private var collector: NetworkCollector?
    private var healthToken: PerfCadenceToken?

    public init(options: PerfNetworkMonitorOptions, context: PerfMonitorContext) {
        self.options = options
        self.context = context.scoped(to: Self.descriptor.id)
    }

    public func start() async throws {
        guard collector == nil else { return }

        let collector = NetworkCollector(recorder: context.recorder, options: options)
        self.collector = collector
        PerfNetworkObserver.install(collector)

        let windowMs = options.healthWindowInterval.milliseconds
        let recorder = context.recorder
        let timeoutRateWarning = options.timeoutRateWarning

        healthToken = context.scheduler.schedule(
            label: "\(Self.descriptor.id).health",
            interval: options.healthWindowInterval
        ) { tick in
            guard let sample = collector.drainWindow(windowMs: windowMs) else { return }
            recorder.record(
                sample,
                severity: sample.timeoutRate >= timeoutRateWarning ? .warning : .info,
                timestamp: tick.date,
                uptimeNanos: tick.uptimeNanos
            )
        }
    }

    public func stop() async {
        PerfNetworkObserver.install(nil)
        collector = nil

        if let healthToken {
            context.scheduler.cancel(healthToken)
        }
        healthToken = nil
    }

    public func apply(_ options: PerfNetworkMonitorOptions) async {
        self.options = options
    }
}
