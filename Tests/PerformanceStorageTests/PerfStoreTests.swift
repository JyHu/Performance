import Foundation
import Testing

import PerformanceCore
@testable import PerformanceStorage

@Suite("PerfStore")
struct PerfStoreTests {
    private let session = PerfSessionID(rawValue: "20260920T103045-AAAAAA")

    private func makeStore(
        root: URL,
        maxShardBytes: PerfByteCount = .megabytes(2),
        compress: Bool = false,
        redaction: PerfRedactionPolicy = .disabled
    ) throws -> PerfStore {
        try PerfStore(
            session: session,
            options: makeOptions(root: root, maxShardBytes: maxShardBytes, compress: compress),
            redaction: redaction,
            enabledMonitors: ["hang", "resource"]
        )
    }

    private func sessionDirectory(root: URL) -> URL {
        PerfShardLocator(root: root).directory(for: session)
    }

    @Test("按 kind 大类分流到不同分片文件")
    func separatesByKindGroup() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url)

        await store.append([
            makeRecord(StorageSample(index: 1)),
            makeRecord(HangSample(durationMs: 3_200)),
            makeRecord(StorageSample(index: 2)),
        ])
        await store.closeShards()

        let names = fileNames(in: sessionDirectory(root: temp.url))
        #expect(names.contains("hang-000.jsonl"))
        #expect(names.contains("sample-000.jsonl"))
    }

    @Test("manifest 在 session 建立时立刻写出")
    func writesManifestUpFront() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url)

        // 还没写任何记录，manifest 就该在了——
        // 进程随时可能被杀，没有 manifest 的数据无法判断设备与版本
        let manifest = try #require(await store.manifest(for: session))
        #expect(manifest.sessionID == session)
        #expect(manifest.endedAt == nil)
        #expect(manifest.enabledMonitors == ["hang", "resource"])
        #expect(!manifest.device.systemName.isEmpty)
    }

    @Test("正常结束时写入 endedAt，据此可识别非正常退出")
    func marksNormalTermination() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url)

        #expect(await store.manifest(for: session)?.endedAt == nil)

        await store.finalizeSession(at: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(await store.manifest(for: session)?.endedAt != nil)
    }

    @Test("写入后可完整查回，载荷类型安全")
    func roundTripsRecords() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url)

        await store.append((0..<10).map { makeRecord(StorageSample(index: $0)) })
        await store.closeShards()

        let result = await store.records(in: session, matching: PerfRecordFilter(kinds: [StorageSample.kind]))
        #expect(result.records.count == 10)
        #expect(result.isComplete)

        let indices = try result.records.map { try $0.decodePayload(as: StorageSample.self).index }
        #expect(indices.sorted() == Array(0..<10))
    }

    @Test("按 kind 查询只打开相关分片")
    func skipsIrrelevantShards() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url)

        await store.append([
            makeRecord(StorageSample(index: 1)),
            makeRecord(HangSample(durationMs: 100)),
        ])
        await store.closeShards()

        let shards = await store.shards(
            in: session,
            matching: PerfRecordFilter(kinds: [HangSample.kind])
        )
        // 这是「按大类分文件」这个约定的兑现：sample-*.jsonl 根本不会被打开
        #expect(shards.map(\.group) == ["hang"])
    }

    @Test("结果按时间排序")
    func sortsByTimestamp() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url)

        let base = Date(timeIntervalSince1970: 1_790_000_000)
        await store.append([
            makeRecord(StorageSample(index: 3), timestamp: base.addingTimeInterval(30)),
            makeRecord(StorageSample(index: 1), timestamp: base.addingTimeInterval(10)),
            makeRecord(StorageSample(index: 2), timestamp: base.addingTimeInterval(20)),
        ])
        await store.closeShards()

        let result = await store.records(in: session)
        let indices = try result.records.map { try $0.decodePayload(as: StorageSample.self).index }
        #expect(indices == [1, 2, 3])
    }

    @Test("滚动后的分片被压缩归档，正在写的那个不动")
    func archivesCompletedShardsOnly() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url, maxShardBytes: .bytes(300), compress: true)

        await store.append((0..<30).map { makeRecord(StorageSample(index: $0)) })
        await store.closeShards()

        let names = fileNames(in: sessionDirectory(root: temp.url))
        #expect(names.contains { $0.hasSuffix(".jsonl.gz") })
        // 当前正在写的分片保持未压缩——压缩一个还在 append 的文件只会得到残缺快照
        #expect(names.contains { $0.hasSuffix(".jsonl") })
    }

    @Test("归档分片仍可被正常查询")
    func readsArchivedShards() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url, maxShardBytes: .bytes(300), compress: true)

        await store.append((0..<30).map { makeRecord(StorageSample(index: $0)) })
        await store.closeShards()

        let result = await store.records(in: session)
        #expect(result.records.count == 30)

        let indices = try result.records.map { try $0.decodePayload(as: StorageSample.self).index }
        #expect(Set(indices) == Set(0..<30))
    }

    @Test("落盘前应用脱敏，敏感内容不会进入磁盘")
    func appliesRedactionBeforeWriting() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url, redaction: .strict)

        await store.append([
            makeRecord(NetworkSample(url: "https://api.example.com/users/42?token=SECRET", totalMs: 120))
        ])
        await store.closeShards()

        let raw = try Data(contentsOf: sessionDirectory(root: temp.url)
            .appendingPathComponent("network-000.jsonl"))
        let text = String(decoding: raw, as: UTF8.self)

        #expect(!text.contains("SECRET"))
        #expect(!text.contains("/users/42"))
        #expect(text.contains("api.example.com"))
    }

    @Test("导出的归档是标准 gzip，且内容完整")
    func exportsGzippedArchive() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url)

        await store.append((0..<5).map { makeRecord(StorageSample(index: $0)) })
        await store.closeShards()

        let destination = temp.url.appendingPathComponent("export/perf.jsonl.gz")
        try await store.exportArchive(to: destination)

        let compressed = try Data(contentsOf: destination)
        let plain = try #require(PerfGzip.decompress(compressed))
        let lineCount = plain.filter { $0 == 0x0A }.count
        #expect(lineCount == 5)
    }

    @Test("查询结果能自述完整性")
    func reportsIncompleteness() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url)

        await store.append([makeRecord(StorageSample(index: 1))])
        await store.closeShards()

        // 手工追加一行坏数据，模拟写入侧出问题
        let shard = sessionDirectory(root: temp.url).appendingPathComponent("sample-000.jsonl")
        var content = try Data(contentsOf: shard)
        content.append(Data("{ broken\n".utf8))
        try content.write(to: shard)

        let result = await store.records(in: session)
        #expect(result.records.count == 1)
        #expect(result.skippedLineCount == 1)
        // 基于残缺数据下结论比没有结论更危险，所以完整性必须可查
        #expect(!result.isComplete)
    }

    @Test("多个 session 可被发现并按时间倒序列出")
    func listsSessionsNewestFirst() async throws {
        let temp = TemporaryDirectory()
        let locator = PerfShardLocator(root: temp.url)

        for id in ["20260918T100000-AAAAAA", "20260920T100000-CCCCCC", "20260919T100000-BBBBBB"] {
            try FileManager.default.createDirectory(
                at: locator.directory(for: PerfSessionID(rawValue: id)),
                withIntermediateDirectories: true
            )
        }

        let store = try makeStore(root: temp.url)
        let sessions = await store.availableSessions().map(\.rawValue)

        #expect(sessions.first == "20260920T103045-AAAAAA")   // 当前 session 最新
        #expect(sessions.contains("20260920T100000-CCCCCC"))
        #expect(sessions == sessions.sorted(by: >))
    }

    @Test("编码失败的记录被计数，不拖垮整批")
    func countsEncodingFailures() async throws {
        let temp = TemporaryDirectory()
        let store = try makeStore(root: temp.url)

        await store.append([
            makeRecord(StorageSample(index: 1)),
            makeRecord(UnencodablePayload()),
            makeRecord(StorageSample(index: 2)),
        ])
        await store.closeShards()

        #expect(await store.encodingFailureCount == 1)
        // 好的记录照常落盘
        let result = await store.records(in: session, matching: PerfRecordFilter(kinds: [StorageSample.kind]))
        #expect(result.records.count == 2)
    }
}

/// 编码时必定抛错的载荷，用于验证单条失败不影响整批。
private struct UnencodablePayload: PerfPayload {
    static let kind: PerfKind = "broken.payload"

    func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(
            self,
            EncodingError.Context(codingPath: [], debugDescription: "故意失败")
        )
    }

    init() {}
    init(from decoder: any Decoder) throws { self.init() }
}

// MARK: - 管道

@Suite("PerfStoragePipeline")
struct PerfStoragePipelineTests {
    private let session = PerfSessionID(rawValue: "20260920T103045-BBBBBB")

    private func makePipeline(
        root: URL,
        bufferCapacity: Int = 100,
        minimumSeverity: PerfSeverity = .info
    ) throws -> (PerfRecordBuffer, PerfStore, PerfStoragePipeline, PerfManualClock) {
        let buffer = PerfRecordBuffer(capacity: bufferCapacity)
        let store = try PerfStore(
            session: session,
            options: makeOptions(root: root),
            redaction: .disabled
        )
        let clock = PerfManualClock()
        let pipeline = PerfStoragePipeline(
            buffer: buffer,
            store: store,
            options: PerfPipelineOptions(
                bufferCapacity: bufferCapacity,
                minimumSeverity: minimumSeverity
            ),
            sessionID: session,
            clock: clock
        )
        return (buffer, store, pipeline, clock)
    }

    @Test("缓冲中的记录被搬运到存储")
    func movesRecordsToStore() async throws {
        let temp = TemporaryDirectory()
        let (buffer, store, pipeline, _) = try makePipeline(root: temp.url)

        for i in 0..<5 {
            buffer.submit(makeRecord(StorageSample(index: i), session: session))
        }
        await pipeline.drain()
        await store.closeShards()

        let result = await store.records(in: session, matching: PerfRecordFilter(kinds: [StorageSample.kind]))
        #expect(result.records.count == 5)
        #expect(await pipeline.pendingCount() == 0)
    }

    @Test("缓冲溢出时把丢弃数作为指标落盘")
    func recordsDroppedCountAsMetric() async throws {
        let temp = TemporaryDirectory()
        let (buffer, store, pipeline, _) = try makePipeline(root: temp.url, bufferCapacity: 3)

        for i in 0..<10 {
            buffer.submit(makeRecord(StorageSample(index: i), session: session))
        }
        await pipeline.drain()
        await store.closeShards()

        let dropped = await store.records(
            in: session,
            matching: PerfRecordFilter(kinds: [PerfDroppedRecords.kind])
        )
        let payload = try #require(try dropped.records.first?.decodePayload(as: PerfDroppedRecords.self))

        // 数据缺口必须可见，否则会被误读成「这段时间没问题」
        #expect(payload.count == 7)
        #expect(payload.cumulative == 7)
        #expect(dropped.records.first?.severity == .warning)
    }

    @Test("低于最低严重度的记录被过滤")
    func filtersBelowMinimumSeverity() async throws {
        let temp = TemporaryDirectory()
        let (buffer, store, pipeline, _) = try makePipeline(root: temp.url, minimumSeverity: .warning)

        buffer.submit(makeRecord(StorageSample(index: 1), session: session, severity: .debug))
        buffer.submit(makeRecord(StorageSample(index: 2), session: session, severity: .critical))
        await pipeline.drain()
        await store.closeShards()

        let result = await store.records(in: session, matching: PerfRecordFilter(kinds: [StorageSample.kind]))
        #expect(result.records.count == 1)
        #expect(try result.records.first?.decodePayload(as: StorageSample.self).index == 2)
    }

    @Test("导出器收到同一批数据")
    func forwardsToExporters() async throws {
        let temp = TemporaryDirectory()
        let (buffer, _, pipeline, _) = try makePipeline(root: temp.url)

        let collected = BatchCollector()
        await pipeline.addExporter(
            PerfClosureExporter { batch in await collected.record(batch.records.count) }
        )

        for i in 0..<3 {
            buffer.submit(makeRecord(StorageSample(index: i), session: session))
        }
        await pipeline.drain()

        #expect(await collected.counts == [3])
    }

    @Test("导出器抛错不影响落盘，也不会连累其他导出器")
    func isolatesExporterFailures() async throws {
        let temp = TemporaryDirectory()
        let (buffer, store, pipeline, _) = try makePipeline(root: temp.url)

        let collected = BatchCollector()
        await pipeline.addExporter(
            PerfClosureExporter(identifier: "failing") { _ in
                struct Boom: Error {}
                throw Boom()
            }
        )
        await pipeline.addExporter(
            PerfClosureExporter(identifier: "working") { batch in
                await collected.record(batch.records.count)
            }
        )

        buffer.submit(makeRecord(StorageSample(index: 1), session: session))
        await pipeline.drain()
        await store.closeShards()

        #expect(await collected.counts == [1])
        let result = await store.records(in: session, matching: PerfRecordFilter(kinds: [StorageSample.kind]))
        #expect(result.records.count == 1)
    }

    @Test("空缓冲时不产生任何写入")
    func skipsEmptyDrain() async throws {
        let temp = TemporaryDirectory()
        let (_, store, pipeline, _) = try makePipeline(root: temp.url)

        await pipeline.drain()
        #expect(await store.writtenRecordCount == 0)
    }

    private actor BatchCollector {
        private(set) var counts: [Int] = []
        func record(_ count: Int) { counts.append(count) }
    }
}
