//
//  PerfDemo
//  主动制造各类性能问题，验证端到端链路，并测量框架自身开销。
//
//  用法：
//      swift run PerfDemo            # 跑全部场景
//      swift run PerfDemo overhead   # 只跑开销对照
//

import Foundation
import Performance

// MARK: - 输出辅助

func section(_ title: String) {
    print("\n\(String(repeating: "─", count: 60))")
    print("  \(title)")
    print(String(repeating: "─", count: 60))
}

func line(_ text: String) {
    print("  \(text)")
}

// MARK: - 问题制造器

enum Scenario {
    /// 占满 CPU 一段时间。
    static func burnCPU(seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        var accumulator: UInt64 = 0
        while Date() < deadline {
            for index in 0..<200_000 {
                accumulator = accumulator &+ UInt64(index) &* 2_654_435_761
            }
        }
        withExtendedLifetime(accumulator) {}
    }

    /// 分配并真正写入一大块内存。
    ///
    /// 必须逐页写入：只 malloc 不写的话内核不会分配物理页，
    /// 内存足迹根本不会变化。
    static func allocateMemory(megabytes: Int) -> [UInt8] {
        var blob = [UInt8](repeating: 0, count: megabytes * 1_024 * 1_024)
        for index in stride(from: 0, to: blob.count, by: 4_096) {
            blob[index] = 1
        }
        return blob
    }

    /// 在主线程上做同步 I/O。
    ///
    /// 必须真的跑在主线程上：探针只记录主线程上的同步 I/O，
    /// 后台线程上的 I/O 耗时长是正常的、不值得记录。
    /// 用 `@MainActor` 标注，否则在 CLI 里这段会落到协作线程上，
    /// 探针会（正确地）把它过滤掉，场景就白跑了。
    @MainActor
    static func mainThreadFileIO(url: URL, megabytes: Int) {
        let payload = Data(repeating: 0x41, count: megabytes * 1_024 * 1_024)

        PerfIOProbe.measure("write-blob", path: url.path, byteCount: payload.count) {
            // .atomic 强制写临时文件再 rename，绕不过页缓存但更接近真实写入
            try? payload.write(to: url, options: .atomic)
        }
        PerfIOProbe.measure("read-blob", path: url.path) {
            _ = try? Data(contentsOf: url, options: .uncached)
        }
    }

    /// 嵌套打点。
    @MainActor
    static func nestedWork() {
        PerfTrace.measure("page-load") {
            PerfTrace.measure("fetch-config") {
                Thread.sleep(forTimeInterval: 0.05)
            }
            // 同步闭包同样会经 task-local 建立嵌套关系，
            // 不需要为了嵌套而把它写成 async
            PerfTrace.measure("render") {
                PerfTrace.measureLayout("layout-cells") {
                    Thread.sleep(forTimeInterval: 0.12)
                }
            }
        }
    }
}

// MARK: - 场景

func runFullDemo() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("PerfDemo", isDirectory: true)
    try? FileManager.default.removeItem(at: root)

    section("启动性能框架")

    // 在真实 app 里这一行应当尽早调用，越早覆盖的启动阶段越完整
    PerfLaunchTimeline.shared.mark(PerfLaunchTimeline.Mark.main)

    var config = PerfConfiguration.debug
    config.storage.directory = root
    config.storage.compressArchivedShards = false   // 方便直接查看
    config.pipeline.drainInterval = .milliseconds(200)
    // demo 里把阈值调低，让快速的 I/O 也能被看见；
    // 真实工程用默认的 8ms（约等于一帧的预算）
    config.enable(PerfDiskMonitor.self) { $0.mainThreadIOThreshold = .milliseconds(1) }

    let warnings = try await PerfCenter.shared.bootstrap(config)
    for warning in warnings {
        line("配置告警：\(warning)")
    }

    let monitors = await PerfCenter.shared.activeMonitorIDs
    line("已启动 \(monitors.count) 个监测器：\(monitors.map(\.rawValue).joined(separator: ", "))")
    line("数据目录：\(root.path)")

    PerfLaunchTimeline.markFirstFrame()

    section("场景 1：CPU 占用")
    Scenario.burnCPU(seconds: 1.5)
    line("已占满 CPU 1.5 秒")

    section("场景 2：内存增长")
    let blob = Scenario.allocateMemory(megabytes: 120)
    line("已分配并写入 120MB")

    section("场景 3：主线程同步 I/O")
    let ioMegabytes = 64
    await Scenario.mainThreadFileIO(
        url: root.appendingPathComponent("blob.bin"),
        megabytes: ioMegabytes
    )
    line("已在主线程完成 \(ioMegabytes)MB 读写")

    section("场景 4：嵌套业务打点")
    await Scenario.nestedWork()
    line("已产出嵌套 span")

    // 给采样和落盘留出时间
    try await Task.sleep(nanoseconds: 2_000_000_000)
    withExtendedLifetime(blob) {}

    section("框架自身健康度")
    let health = await PerfCenter.shared.healthSnapshot()
    line("session：\(health.sessionID?.rawValue ?? "-")")
    line("内存足迹：\(String(format: "%.1f", health.system.memory.footprintMegabytes)) MB")
    line("线程数：\(health.system.threadCount)")
    line("缓冲积压：\(health.pendingBufferCount) 条")
    line("累计丢弃：\(health.droppedRecordCount) 条")
    line("采样跳过：\(health.schedulerSkips.isEmpty ? "无" : "\(health.schedulerSkips)")")
    line("整体健康：\(health.isHealthy ? "是" : "否")")

    section("采集结果")
    let result = await PerfCenter.shared.records()
    line("共 \(result.records.count) 条记录，数据完整：\(result.isComplete ? "是" : "否")")
    if result.skippedLineCount > 0 {
        line("跳过的坏行：\(result.skippedLineCount)")
    }

    var byKind: [String: Int] = [:]
    for record in result.records {
        byKind[record.kind.rawValue, default: 0] += 1
    }
    for (kind, count) in byKind.sorted(by: { $0.key < $1.key }) {
        line(String(format: "  %-28@ %4d 条", kind as NSString, count))
    }

    section("典型记录")
    printSpans(result)
    printResourcePeaks(result)
    printMainThreadIO(result)

    section("导出归档")
    let archive = root.appendingPathComponent("perf-demo.jsonl.gz")
    try await PerfCenter.shared.exportArchive(to: archive)
    let size = (try? Data(contentsOf: archive).count) ?? 0
    line("已导出：\(archive.path)（\(size) 字节）")
    line("可直接查看： zcat \(archive.path) | head")

    let usage = await PerfCenter.shared.diskUsage()
    line("当前磁盘占用：\(usage)")

    await PerfCenter.shared.shutdown()
    line("\n已关闭。manifest 里的 endedAt 已写入，表示本次是正常退出。")
}

func printSpans(_ result: PerfQueryResult) {
    let spans = result.records.compactMap { try? $0.decodePayload(as: PerfSpanSample.self) }
    guard !spans.isEmpty else { return }

    line("业务打点：")
    for span in spans.sorted(by: { $0.depth < $1.depth }) {
        let indent = String(repeating: "  ", count: span.depth + 1)
        line("\(indent)\(span.name)  \(String(format: "%.1f", span.durationMs))ms  [\(span.category.rawValue)]")
    }
}

func printResourcePeaks(_ result: PerfQueryResult) {
    let cpu = result.records.compactMap { try? $0.decodePayload(as: PerfCPUSample.self) }
    if let peak = cpu.max(by: { $0.processPercent < $1.processPercent }) {
        line("CPU 峰值：\(String(format: "%.1f", peak.processPercent))%（窗口 \(String(format: "%.0f", peak.windowMs))ms，\(peak.threadCount) 线程）")
        for thread in peak.topThreads.prefix(3) {
            line("    \(thread.isMain ? "主线程" : (thread.name ?? "后台线程"))  \(String(format: "%.1f", thread.percent))%")
        }
    }

    let memory = result.records.compactMap { try? $0.decodePayload(as: PerfMemorySample.self) }
    if let peak = memory.max(by: { $0.footprintMB < $1.footprintMB }) {
        line("内存峰值：\(String(format: "%.1f", peak.footprintMB)) MB（相对基线增长 \(String(format: "%.1f", peak.growthSinceBaselineMB)) MB）")
    }
}

func printMainThreadIO(_ result: PerfQueryResult) {
    let events = result.records.compactMap { try? $0.decodePayload(as: PerfMainThreadIOEvent.self) }
    guard !events.isEmpty else {
        // 如实说明而不是什么都不显示：没记录本身就是一条信息，
        // 说明这次 I/O 快到不值得关注
        line("主线程同步 I/O：本次均低于阈值，未记录")
        return
    }

    line("主线程同步 I/O：")
    for event in events {
        line("    \(event.operation)  \(String(format: "%.1f", event.durationMs))ms  \(event.path ?? "-")")
    }
}

// MARK: - 开销对照

/// 同一段工作分别在「监控全开」和「监控全关」下各跑一遍，对比耗时。
///
/// 这个对照是框架必须自证的事：一个让 app 变慢的性能监控框架，
/// 测出来的所有数据都已经被它自己污染了。
func runOverheadComparison() async throws {
    section("开销对照")

    let iterations = 12
    func workload() {
        Scenario.burnCPU(seconds: 0.25)
        PerfTrace.measure("workload") {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    // 基线：监控未启动，PerfTrace 退化为空操作
    let baselineStart = Date()
    for _ in 0..<iterations { workload() }
    let baseline = Date().timeIntervalSince(baselineStart)
    line("监控关闭：\(String(format: "%.3f", baseline)) 秒")

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("PerfDemo-overhead", isDirectory: true)
    try? FileManager.default.removeItem(at: root)

    var config = PerfConfiguration.debug
    config.storage.directory = root
    config.isLoggingEnabled = false
    try await PerfCenter.shared.bootstrap(config)

    let monitoredStart = Date()
    for _ in 0..<iterations { workload() }
    let monitored = Date().timeIntervalSince(monitoredStart)
    line("监控全开：\(String(format: "%.3f", monitored)) 秒")

    let overhead = (monitored - baseline) / baseline * 100
    line("额外开销：\(String(format: "%+.1f", overhead))%")

    let health = await PerfCenter.shared.healthSnapshot()
    line("框架自身内存：约 \(String(format: "%.1f", health.system.memory.footprintMegabytes)) MB（含 demo 工作集）")
    line("丢弃记录：\(health.droppedRecordCount) 条")

    await PerfCenter.shared.shutdown()
    try? FileManager.default.removeItem(at: root)
}

// MARK: - 入口

let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("overhead") {
    try await runOverheadComparison()
} else {
    try await runFullDemo()
    try await runOverheadComparison()
}
