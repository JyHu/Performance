import Foundation
import PerformanceCore

/// 把采集缓冲搬运到持久化层与导出器。
///
/// ```
/// 采集点 ──submit──▶ PerfRecordBuffer ──drain──▶ PerfStoragePipeline ──┬──▶ PerfStore (JSONL)
///  (可能在主线程)      (有界、加锁、O(1))         (后台 actor，批量)     └──▶ PerfExporter…
/// ```
///
/// 全部重活——JSON 编码、脱敏、写盘、压缩——都发生在这一层，
/// 也就是**采集点之外**。采集点只做一次 O(1) 的入队。
public actor PerfStoragePipeline {
    private let buffer: PerfRecordBuffer
    private let store: PerfStore
    private let options: PerfPipelineOptions
    private let sessionID: PerfSessionID
    private let clock: any PerfClock
    private let log: PerfLog

    private var exporters: [any PerfExporter] = []
    private var cadenceToken: PerfCadenceToken?
    private weak var scheduler: AnyObject?
    private var schedulerRef: (any PerfScheduling)?

    /// 上次上报丢弃数时的累计值，用于算增量。
    private var lastReportedDropCumulative: UInt64 = 0

    public init(
        buffer: PerfRecordBuffer,
        store: PerfStore,
        options: PerfPipelineOptions,
        sessionID: PerfSessionID,
        clock: any PerfClock,
        log: PerfLog = .disabled
    ) {
        self.buffer = buffer
        self.store = store
        self.options = options
        self.sessionID = sessionID
        self.clock = clock
        self.log = log
    }

    public func addExporter(_ exporter: any PerfExporter) {
        exporters.append(exporter)
    }

    public func removeExporter(identifier: String) {
        exporters.removeAll { $0.identifier == identifier }
    }

    /// 挂到调度器上按周期搬运。
    public func start(scheduler: any PerfScheduling) {
        guard cadenceToken == nil else { return }
        schedulerRef = scheduler
        cadenceToken = scheduler.schedule(
            label: "storage-pipeline",
            interval: options.drainInterval
        ) { [weak self] _ in
            await self?.drain()
        }
    }

    /// 停止搬运，并把缓冲里剩下的数据落盘。
    public func stop() async {
        if let cadenceToken, let schedulerRef {
            schedulerRef.cancel(cadenceToken)
        }
        cadenceToken = nil
        schedulerRef = nil
        await drain()
        await store.closeShards()
    }

    /// 搬运一轮。
    public func drain() async {
        let drained = buffer.drain()

        // 丢弃计数本身也是一条指标。
        // 不上报的话，数据缺口会被当成「这段时间没问题」——
        // 那比没有数据更危险，因为它会误导排查方向。
        var records = Array(drained.records)
        if drained.dropped > 0 {
            records.append(makeDropRecord(drained))
            log.warning("缓冲溢出，本轮丢弃 \(drained.dropped) 条（累计 \(drained.droppedCumulative)）")
        }

        guard !records.isEmpty else { return }

        let accepted = records.filter { $0.severity >= options.minimumSeverity }
        guard !accepted.isEmpty else { return }

        await store.append(accepted)

        guard !exporters.isEmpty else { return }
        let batch = PerfRecordBatch(sessionID: sessionID, records: accepted)
        for exporter in exporters {
            do {
                try await exporter.export(batch)
            } catch {
                // 导出失败不重试：重试策略属于导出器实现者的职责。
                // 框架代劳的后果就是上一版那样——失败的文件每 30 秒重传一次，
                // 无退避、无上限，直到磁盘写满。
                log.error("导出器 \(exporter.identifier) 失败：\(error)")
            }
        }
    }

    /// 当前缓冲积压条数，用于背压观测。
    public func pendingCount() -> Int {
        buffer.count
    }

    private func makeDropRecord(_ drained: PerfRecordBuffer.Drained) -> PerfAnyRecord {
        let delta = drained.droppedCumulative - lastReportedDropCumulative
        lastReportedDropCumulative = drained.droppedCumulative

        return PerfAnyRecord(
            timestamp: clock.now,
            uptimeNanos: clock.uptimeNanos,
            sessionID: sessionID,
            severity: .warning,
            thread: nil,
            kind: PerfDroppedRecords.kind,
            schemaVersion: PerfDroppedRecords.schemaVersion,
            payload: PerfDroppedRecords(count: delta, cumulative: drained.droppedCumulative)
        )
    }
}
