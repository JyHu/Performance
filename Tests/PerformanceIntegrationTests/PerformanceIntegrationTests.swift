import Foundation
import Testing

import Performance

/// 端到端用例共享同一个 `PerfCenter.shared`，必须串行执行。
@Suite("端到端", .serialized)
struct PerformanceIntegrationTests {

    /// 每个用例一个独立的数据目录，用完清理。
    private func makeTemporaryRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("perf-integration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeConfiguration(root: URL) -> PerfConfiguration {
        var config = PerfConfiguration()
        config.storage.directory = root
        config.storage.compressArchivedShards = false
        config.redaction = .disabled
        config.pipeline.drainInterval = .milliseconds(100)
        config.baseSamplingInterval = .milliseconds(100)

        config.enable(PerfTraceMonitor.self) { $0.emitsSignposts = false }
        config.enable(PerfResourceMonitor.self) { $0.interval = .milliseconds(200) }
        return config
    }

    // MARK: - 中心 target 的透出

    @Test("只 import Performance 即可使用基础层类型")
    func umbrellaReExportsCoreTypes() {
        let kind: PerfKind = "hang.anr"
        #expect(kind.group == "hang")

        var config = PerfConfiguration()
        config.storage.totalQuota = .megabytes(20)
        #expect(config.validate().isEmpty)
    }

    @Test("只 import Performance 即可使用采集层类型")
    func umbrellaReExportsCollectorTypes() {
        #expect(PerfHang.Kinds.anr.rawValue == "hang.anr")
        #expect(PerfRendering.monitorID.rawValue == "rendering")
        #expect(PerfSpanSample.kind.group == "trace")
        #expect(PerfCrashReport.kind.group == "crash")
    }

    @Test("各预设的配置都能通过自检")
    func presetsAreValid() {
        for config in [
            PerfConfiguration.production,
            .debug,
            .diagnostic,
            .minimal,
        ] {
            // 平台不匹配的告警在 macOS 上属于正常情况，不算配置错误
            let blocking = config.validate().filter {
                if case .unsupportedPlatform = $0 { return false }
                return true
            }
            #expect(blocking.isEmpty)
            #expect(!config.registrations.isEmpty)
        }
    }

    @Test("预设之间的取舍方向正确")
    func presetsDifferMeaningfully() {
        let production = PerfConfiguration.production
        let debug = PerfConfiguration.debug

        // 生产环境不该把符号名落盘
        #expect(!production.redaction.includeSymbolNames)
        #expect(debug.redaction.includeSymbolNames)
        // 生产环境的磁盘配额应当更小
        #expect(production.storage.totalQuota < debug.storage.totalQuota)
        // 最小预设只管崩溃和卡顿
        #expect(PerfConfiguration.minimal.registrations.count == 2)
    }

    // MARK: - 完整链路

    @Test("bootstrap → 打点 → 落盘 → 查回")
    func endToEndRoundTrip() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await PerfCenter.shared.bootstrap(makeConfiguration(root: root))
        defer { Task { await PerfCenter.shared.shutdown() } }

        #expect(await PerfCenter.shared.isActive)
        #expect(await PerfCenter.shared.activeMonitorIDs.contains("trace"))

        PerfTrace.measure("integration-work") {
            Thread.sleep(forTimeInterval: 0.02)
        }

        let result = await PerfCenter.shared.records(
            matching: PerfRecordFilter(kinds: [PerfSpanSample.kind])
        )
        #expect(!result.isEmpty)
        #expect(result.isComplete)

        let span = try #require(try result.records.first?.decodePayload(as: PerfSpanSample.self))
        #expect(span.name == "integration-work")
        #expect(span.durationMs >= 15)

        await PerfCenter.shared.shutdown()
    }

    @Test("session 目录结构与 manifest 都建立起来了")
    func createsSessionLayout() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await PerfCenter.shared.bootstrap(makeConfiguration(root: root))
        let session = try #require(await PerfCenter.shared.currentSessionID)

        PerfTrace.measure("touch") {}
        _ = await PerfCenter.shared.records()

        let sessionDirectory = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(session.rawValue, isDirectory: true)

        let names = try FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path)
        #expect(names.contains("manifest.json"))
        #expect(names.contains { $0.hasPrefix("trace-") && $0.hasSuffix(".jsonl") })

        let manifestData = try Data(
            contentsOf: sessionDirectory.appendingPathComponent("manifest.json")
        )
        let manifest = try JSONDecoder().decode(PerfSessionManifest.self, from: manifestData)
        #expect(manifest.sessionID == session)
        #expect(manifest.enabledMonitors.contains("trace"))
        // 进程还活着，正常结束标记应当为空
        #expect(manifest.endedAt == nil)

        await PerfCenter.shared.shutdown()
    }

    @Test("shutdown 后写入正常结束标记，据此可识别非正常退出")
    func marksCleanShutdown() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await PerfCenter.shared.bootstrap(makeConfiguration(root: root))
        let session = try #require(await PerfCenter.shared.currentSessionID)
        await PerfCenter.shared.shutdown()

        let manifestURL = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(session.rawValue, isDirectory: true)
            .appendingPathComponent("manifest.json")

        let manifest = try JSONDecoder().decode(
            PerfSessionManifest.self,
            from: try Data(contentsOf: manifestURL)
        )
        // endedAt 为 nil 即表示进程是被杀掉的：崩溃、OOM、看门狗终止
        // 都会留下这个痕迹，本身就是一条有价值的信息
        #expect(manifest.endedAt != nil)
    }

    @Test("导出的归档是标准 gzip，可直接 zcat")
    func exportsReadableArchive() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await PerfCenter.shared.bootstrap(makeConfiguration(root: root))

        for index in 0..<5 {
            PerfTrace.measure("work-\(index)") {}
        }

        let destination = root.appendingPathComponent("export.jsonl.gz")
        try await PerfCenter.shared.exportArchive(to: destination)

        let compressed = try Data(contentsOf: destination)
        #expect(compressed[0] == 0x1F && compressed[1] == 0x8B)   // gzip magic

        let plain = try #require(PerfGzip.decompress(compressed))
        let text = String(decoding: plain, as: UTF8.self)
        #expect(text.contains("work-0"))
        #expect(text.contains("trace.span"))

        await PerfCenter.shared.shutdown()
    }

    @Test("健康快照反映框架自身状态")
    func reportsHealthSnapshot() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await PerfCenter.shared.bootstrap(makeConfiguration(root: root))

        let snapshot = await PerfCenter.shared.healthSnapshot()
        #expect(snapshot.sessionID != nil)
        #expect(snapshot.activeMonitors.contains("trace"))
        #expect(snapshot.system.memory.footprintBytes > 0)
        // 刚启动，不该有丢弃或采样跳过
        #expect(snapshot.isHealthy)

        await PerfCenter.shared.shutdown()
    }

    @Test("重复 bootstrap 不会产生第二套监测器")
    func bootstrapIsIdempotent() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfiguration(root: root)
        try await PerfCenter.shared.bootstrap(config)
        let first = await PerfCenter.shared.activeMonitorIDs

        try await PerfCenter.shared.bootstrap(config)
        let second = await PerfCenter.shared.activeMonitorIDs

        #expect(first == second)

        await PerfCenter.shared.shutdown()
    }

    @Test("shutdown 后打点退化为空操作，不再产出也不崩溃")
    func tracingBecomesNoOpAfterShutdown() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await PerfCenter.shared.bootstrap(makeConfiguration(root: root))
        await PerfCenter.shared.shutdown()

        #expect(!(await PerfCenter.shared.isActive))
        #expect(PerfTrace.begin("after-shutdown") == nil)

        // body 照常执行，只是不记录——业务方无需判空
        let value = PerfTrace.measure("after-shutdown") { 99 }
        #expect(value == 99)
    }

    @Test("导出器收到与落盘相同的数据")
    func forwardsToInjectedExporter() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await PerfCenter.shared.bootstrap(makeConfiguration(root: root))

        let collector = RecordCollector()
        await PerfCenter.shared.addExporter(
            PerfClosureExporter(identifier: "test") { batch in
                await collector.add(batch.records.map(\.kind))
            }
        )

        PerfTrace.measure("exported") {}
        _ = await PerfCenter.shared.records()

        #expect(await collector.kinds.contains(PerfSpanSample.kind))

        await PerfCenter.shared.shutdown()
    }

    @Test("启动时清理历史 session，不让遗留数据占满配额")
    func enforcesRetentionOnBootstrap() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // 造一个 2023 年的陈旧 session
        let stale = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("20230101T000000-OLD001", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 1_024)
            .write(to: stale.appendingPathComponent("hang-000.jsonl"))

        var config = makeConfiguration(root: root)
        config.storage.retention = .days(7)
        try await PerfCenter.shared.bootstrap(config)

        #expect(!FileManager.default.fileExists(atPath: stale.path))

        await PerfCenter.shared.shutdown()
    }

    private actor RecordCollector {
        private(set) var kinds: [PerfKind] = []
        func add(_ newKinds: [PerfKind]) { kinds.append(contentsOf: newKinds) }
    }
}
