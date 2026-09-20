import Foundation
import PerformanceBacktrace
import PerformanceCore
import PerformanceStorage
import PerformanceSystemKit

/// 框架的编排入口。
///
/// ## 它只做编排，不含任何监测逻辑
///
/// 上一版的 `PMMonitor.start()` 是一段 96 行的
/// `if config.enableX { x = X(...); x.start() }` 流水账，`stop()` 又是对称的一段；
/// 每加一个监测项都要改四处（配置字段、门面属性、start、stop）。
/// 而且这个门面本身还塞了 trace/measure/recordEvent 三个功能方法——
/// 三者的方法体是逐行相同的复制粘贴。
///
/// 这里的 `start` 只是遍历配置里的注册项。新增监测器**不需要改这个文件**。
public actor PerfCenter {
    public static let shared = PerfCenter()

    private var monitors: [PerfAnyMonitor] = []
    private var configuration: PerfConfiguration?
    private var sessionID: PerfSessionID?
    private var store: PerfStore?
    private var pipeline: PerfStoragePipeline?
    private var scheduler: PerfScheduler?
    private var buffer: PerfRecordBuffer?
    private var log = PerfLog(category: "center", isEnabled: false)

    private init() {}

    // MARK: - 生命周期

    /// 启动框架。
    ///
    /// 重复调用是安全的：已启动时直接返回，不会产生第二套监测器。
    ///
    /// - Returns: 配置自检产生的告警。空数组表示配置无问题。
    ///   告警不会阻止启动——性能框架配置不当不该让 app 起不来。
    @discardableResult
    public func bootstrap(_ configuration: PerfConfiguration) async throws -> [PerfConfiguration.Warning] {
        guard monitors.isEmpty else {
            log.warning("框架已启动，忽略重复的 bootstrap 调用")
            return []
        }

        // 主线程端口必须尽早登记：之后所有「抓主线程栈」「判断是否主线程」
        // 都依赖它。没登记的话这些功能会静默失效——不报错，只是数据悄悄变错。
        await MainActor.run {
            PerfBacktrace.registerMainThread()
        }

        self.configuration = configuration
        self.log = PerfLog(category: "center", isEnabled: configuration.isLoggingEnabled)

        let warnings = configuration.validate()
        for warning in warnings {
            log.warning(warning.description)
        }

        let session = PerfSessionID.generate()
        sessionID = session

        let buffer = PerfRecordBuffer(capacity: configuration.pipeline.bufferCapacity)
        self.buffer = buffer

        let clock = PerfSystemClock()
        let scheduler = PerfScheduler(
            baseInterval: configuration.baseSamplingInterval,
            clock: clock,
            log: log.scoped("scheduler")
        )
        self.scheduler = scheduler

        let store = try PerfStore(
            session: session,
            options: configuration.storage,
            redaction: configuration.redaction,
            enabledMonitors: configuration.enabledMonitorIDs,
            log: log.scoped("store")
        )
        self.store = store

        let pipeline = PerfStoragePipeline(
            buffer: buffer,
            store: store,
            options: configuration.pipeline,
            sessionID: session,
            clock: clock,
            log: log.scoped("pipeline")
        )
        self.pipeline = pipeline
        await pipeline.start(scheduler: scheduler)

        // 启动时先清一次，避免上次遗留的数据把配额占满
        let retention = await store.enforceRetention()
        if retention.totalDeletedSessions > 0 {
            log.info("清理了 \(retention.totalDeletedSessions) 个历史 session")
        }

        let context = PerfMonitorContext(
            recorder: PerfRecorder(
                sink: PerfBufferSink(buffer: buffer),
                sessionID: session,
                clock: clock
            ),
            scheduler: scheduler,
            clock: clock,
            log: log,
            backtrace: PerfBacktraceService(),
            lifecycle: PerfAppLifecycle(clock: clock)
        )

        // 整个 start 流程的核心就是这个循环。
        // 新增监测器只需实现协议并在配置里 enable，这个文件不用动。
        for registration in configuration.registrations {
            guard registration.descriptor.platforms.isAvailableOnCurrentPlatform else {
                log.info("跳过 \(registration.descriptor.id)：不支持当前平台")
                continue
            }

            let monitor = registration.makeMonitor(context: context)
            do {
                try await monitor.start()
                monitors.append(monitor)
            } catch {
                // 一个监测器起不来不该拖垮其他的
                log.error("监测器 \(registration.descriptor.id) 启动失败：\(error)")
            }
        }

        log.info("已启动 \(monitors.count) 个监测器，session \(session)")
        return warnings
    }

    /// 停止全部监测并把缓冲落盘。
    public func shutdown() async {
        // 逆序停止：后启动的可能依赖先启动的
        for monitor in monitors.reversed() {
            await monitor.stop()
        }
        monitors.removeAll()

        await pipeline?.stop()
        await store?.finalizeSession()
        scheduler?.shutdown()

        pipeline = nil
        store = nil
        scheduler = nil
        buffer = nil
        sessionID = nil
        configuration = nil
    }

    // MARK: - 查询

    public var isActive: Bool { !monitors.isEmpty }

    public var activeMonitorIDs: [PerfMonitorID] {
        monitors.map(\.descriptor.id)
    }

    public var currentSessionID: PerfSessionID? { sessionID }

    /// 当前实时健康快照。
    ///
    /// 与落盘数据是两回事：这个是「此刻」的状态，用于调试面板；
    /// 落盘数据是时间序列，用于事后排查。
    public func healthSnapshot() -> PerfHealthSnapshot {
        PerfHealthSnapshot(
            sessionID: sessionID,
            activeMonitors: monitors.map(\.descriptor.id.rawValue),
            system: PerfSystemSnapshot.capture(),
            pendingBufferCount: buffer?.count ?? 0,
            droppedRecordCount: buffer?.totalDropped ?? 0,
            schedulerSkips: scheduler?.skipCounts() ?? [:]
        )
    }

    /// 查询已落盘的记录。
    public func records(matching filter: PerfRecordFilter = .all) async -> PerfQueryResult {
        guard let store else { return PerfQueryResult() }
        // 先把缓冲里的搬下去，否则刚产生的数据查不到
        await pipeline?.drain()
        return await store.records(matching: filter)
    }

    /// 把匹配的记录打包成单个 gzip 压缩的 JSONL 文件。
    ///
    /// 产物可以直接附到 bug 单上，接收方 `zcat` 就能看。
    @discardableResult
    public func exportArchive(
        matching filter: PerfRecordFilter = .all,
        to destination: URL
    ) async throws -> URL {
        guard let store else {
            throw PerfStorageError.cachesDirectoryUnavailable
        }
        await pipeline?.drain()
        return try await store.exportArchive(matching: filter, to: destination)
    }

    /// 当前磁盘占用。
    public func diskUsage() async -> PerfByteCount {
        await store?.currentDiskUsage() ?? .zero
    }

    // MARK: - 导出器

    /// 注入上报实现。
    ///
    /// 框架自身**零网络依赖**：上报涉及的每件事（endpoint、鉴权、采样率、
    /// 重试策略、合规要求）都是业务决策。上一版替业务方做了这些决定，
    /// 结果是默认配置里硬编码了一个明文 HTTP 的内网 IP，
    /// 上传失败的文件每 30 秒重传一次直到磁盘写满。
    public func addExporter(_ exporter: any PerfExporter) async {
        await pipeline?.addExporter(exporter)
    }

    public func removeExporter(identifier: String) async {
        await pipeline?.removeExporter(identifier: identifier)
    }
}

/// 实时健康快照。
public struct PerfHealthSnapshot: Sendable {
    public let sessionID: PerfSessionID?
    public let activeMonitors: [String]
    public let system: PerfSystemSnapshot
    /// 缓冲中待落盘的条数。持续偏高说明落盘跟不上采集速度。
    public let pendingBufferCount: Int
    /// 累计丢弃条数。非零意味着数据有缺口。
    public let droppedRecordCount: UInt64
    /// 因上一次回调未跑完而被跳过的采样次数，按监测器汇总。
    ///
    /// 非零说明某个监测器的单次采样耗时超过了它自己的周期——
    /// 那是这个监测器有问题的明确信号。
    public let schedulerSkips: [String: UInt64]

    /// 框架自身是否运行健康。
    public var isHealthy: Bool {
        droppedRecordCount == 0 && schedulerSkips.isEmpty
    }
}
