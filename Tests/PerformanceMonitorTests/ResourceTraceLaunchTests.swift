import Foundation
import Testing

import PerformanceCore
@testable import PerformanceLaunch
@testable import PerformanceResource
@testable import PerformanceTrace

// MARK: - 资源监测

@Suite("资源监测")
struct ResourceMonitorTests {
    /// 已启动的监测器。必须整体持有——调度器闭包对监测器是弱引用。
    private func startMonitor(
        harness: MonitorHarness,
        configure: (inout PerfResourceMonitorOptions) -> Void = { _ in }
    ) async throws -> PerfResourceMonitor {
        var options = PerfResourceMonitorOptions()
        options.interval = .milliseconds(100)
        configure(&options)

        let monitor = PerfResourceMonitor(options: options, context: harness.context)
        try await monitor.start()
        return monitor
    }

    @Test("按周期产出 CPU 与内存采样")
    func emitsSamplesOnCadence() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)

        await harness.scheduler.tick(times: 5)

        #expect(!harness.payloads(of: PerfMemorySample.self).isEmpty)
        #expect(!harness.payloads(of: PerfCPUSample.self).isEmpty)
        withExtendedLifetime(monitor) {}
    }

    @Test("内存采样带上相对基线的增长量")
    func reportsMemoryGrowth() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)

        await harness.scheduler.tick(times: 3)

        let sample = try #require(harness.payloads(of: PerfMemorySample.self).first)
        #expect(sample.footprintMB > 0)
        // 绝对值高不一定是问题；持续增长才是泄漏的信号，所以要单独成一个维度
        #expect(sample.growthSinceBaselineMB >= 0)
        withExtendedLifetime(monitor) {}
    }

    @Test("足迹不超过常驻内存")
    func footprintNotAboveResident() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)
        await harness.scheduler.tick(times: 3)

        let sample = try #require(harness.payloads(of: PerfMemorySample.self).first)
        #expect(sample.footprintMB <= sample.residentMB)
        withExtendedLifetime(monitor) {}
    }

    @Test("CPU 采样带上统计窗口时长")
    func cpuSampleCarriesWindow() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)
        await harness.scheduler.tick(times: 5)

        let sample = try #require(harness.payloads(of: PerfCPUSample.self).first)
        // 百分比脱离时间窗口无法跨采样周期比较
        #expect(sample.windowMs > 0)
        #expect(sample.threadCount > 0)
        withExtendedLifetime(monitor) {}
    }

    @Test("内存阈值超限时定级升高")
    func raisesSeverityOverMemoryThreshold() async throws {
        let harness = MonitorHarness()
        // 阈值压到极低，保证一定触发
        let monitor = try await startMonitor(harness: harness) {
            $0.memoryWarningMB = 0.001
            $0.memoryCriticalMB = 1_000_000
        }
        await harness.scheduler.tick(times: 3)

        let record = try #require(harness.records(ofKind: PerfMemorySample.kind).first)
        #expect(record.severity == .warning)
        withExtendedLifetime(monitor) {}
    }

    @Test("关闭常规采样后只留超阈值的记录")
    func suppressesNormalSamples() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness) {
            $0.recordsNormalSamples = false
            $0.memoryWarningMB = 1_000_000      // 不会触发
            $0.cpuWarningPercent = 1_000_000
        }
        await harness.scheduler.tick(times: 10)

        #expect(harness.payloads(of: PerfMemorySample.self).isEmpty)
        #expect(harness.payloads(of: PerfCPUSample.self).isEmpty)
        withExtendedLifetime(monitor) {}
    }

    @Test("Top 线程数量受配置限制")
    func limitsTopThreadCount() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness) { $0.topThreadCount = 2 }
        await harness.scheduler.tick(times: 5)

        let sample = try #require(harness.payloads(of: PerfCPUSample.self).first)
        // 全记会让数据量膨胀数倍，排查真正需要的只有最忙的那几个
        #expect(sample.topThreads.count <= 2)
        withExtendedLifetime(monitor) {}
    }

    @Test("停止后不再产出")
    func stopsCleanly() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)

        await harness.scheduler.tick(times: 3)
        await monitor.stop()
        harness.sink.reset()

        await harness.scheduler.tick(times: 10)
        #expect(harness.sink.records.isEmpty)
    }
}

// MARK: - 依赖进程级入口的监测器

/// `PerfTrace` 与 `PerfLaunchTimeline` 是进程级入口——业务代码要从任意位置
/// 调用它们，不可能要求每个调用点先拿到 `PerfMonitorContext`。
///
/// 代价是这些用例共享同一份全局状态，并行跑会互相踩。
/// `.serialized` 作用于整个子树，把它们串起来执行。
@Suite("进程级入口", .serialized)
struct ProcessWideEntryPointTests {

@Suite("自定义打点")
struct TraceMonitorTests {
    private func startMonitor(
        harness: MonitorHarness,
        configure: (inout PerfTraceMonitorOptions) -> Void = { _ in }
    ) async throws -> PerfTraceMonitor {
        var options = PerfTraceMonitorOptions()
        options.emitsSignposts = false
        configure(&options)

        let monitor = PerfTraceMonitor(options: options, context: harness.context)
        try await monitor.start()
        return monitor
    }

    @Test("配对的 begin / end 产出一条耗时记录")
    func recordsExplicitSpan() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)

        let token = try #require(PerfTrace.begin("load-config"))
        harness.clock.advance(by: .milliseconds(120))
        PerfTrace.end(token)

        let span = try #require(harness.payloads(of: PerfSpanSample.self).first)
        #expect(span.name == "load-config")
        #expect(abs(span.durationMs - 120) < 0.001)
        #expect(span.depth == 0)
        #expect(!span.wasAbandoned)

        await monitor.stop()
    }

    @Test("闭包形式自动配对")
    func measuresClosure() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)

        let result = PerfTrace.measure("compute") { () -> Int in
            harness.clock.advance(by: .milliseconds(50))
            return 42
        }

        #expect(result == 42)
        let span = try #require(harness.payloads(of: PerfSpanSample.self).first)
        #expect(abs(span.durationMs - 50) < 0.001)

        await monitor.stop()
    }

    @Test("body 抛错时仍然结算，并标记为未正常结束")
    func settlesOnThrow() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try PerfTrace.measure("risky") {
                harness.clock.advance(by: .milliseconds(10))
                throw Boom()
            }
        }

        // 不结算的话，业务代码一出错这条 span 就永远没有终点
        let span = try #require(harness.payloads(of: PerfSpanSample.self).first)
        #expect(span.wasAbandoned)
        #expect(harness.records(ofKind: PerfSpanSample.kind).first?.severity == .warning)

        await monitor.stop()
    }

    @Test("异步嵌套自动建立父子关系")
    func nestsAsyncSpans() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)

        await PerfTrace.measure("outer") {
            await PerfTrace.measure("inner") {
                harness.clock.advance(by: .milliseconds(30))
            }
        }

        let spans = harness.payloads(of: PerfSpanSample.self)
        let inner = try #require(spans.first { $0.name == "inner" })
        let outer = try #require(spans.first { $0.name == "outer" })

        #expect(inner.parentName == "outer")
        #expect(inner.depth == 1)
        #expect(outer.depth == 0)
        #expect(outer.parentName == nil)

        await monitor.stop()
    }

    @Test("慢 span 定级升高")
    func raisesSeverityForSlowSpans() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness) {
            $0.slowThreshold = .milliseconds(100)
            $0.verySlowThreshold = .seconds(1)
        }

        PerfTrace.measure("fast") { harness.clock.advance(by: .milliseconds(10)) }
        PerfTrace.measure("slow") { harness.clock.advance(by: .milliseconds(500)) }
        PerfTrace.measure("very-slow") { harness.clock.advance(by: .seconds(3)) }

        let records = harness.records(ofKind: PerfSpanSample.kind)
        #expect(records.count == 3)

        func severity(of name: String) -> PerfSeverity? {
            records.first { $0.payload(as: PerfSpanSample.self)?.name == name }?.severity
        }
        #expect(severity(of: "fast") == .info)
        #expect(severity(of: "slow") == .warning)
        #expect(severity(of: "very-slow") == .error)

        await monitor.stop()
    }

    @Test("时间戳取 span 开始时刻，不是结束时刻")
    func stampsAtSpanStart() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)

        let startUptime = harness.clock.uptimeNanos
        PerfTrace.measure("long") { harness.clock.advance(by: .seconds(5)) }

        let record = try #require(harness.records(ofKind: PerfSpanSample.kind).first)
        // 按结束时刻落盘的话，这条 span 在时间线上会与同期的 CPU、内存采样错位 5 秒
        #expect(record.uptimeNanos == startUptime)

        await monitor.stop()
    }

    @Test("分类被保留")
    func preservesCategory() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)

        PerfTrace.measurePage("home") {}
        PerfTrace.measureLayout("cell") {}

        let spans = harness.payloads(of: PerfSpanSample.self)
        #expect(spans.first { $0.name == "home" }?.category == .page)
        #expect(spans.first { $0.name == "cell" }?.category == .layout)

        await monitor.stop()
    }

    @Test("停止后打点退化为空操作，不再产出也不崩溃")
    func becomesNoOpAfterStop() async throws {
        let harness = MonitorHarness()
        let monitor = try await startMonitor(harness: harness)
        await monitor.stop()

        harness.sink.reset()

        #expect(PerfTrace.begin("after-stop") == nil)
        let value = PerfTrace.measure("after-stop") { 7 }

        // body 照常执行，只是不记录——业务方无需判空
        #expect(value == 7)
        #expect(harness.sink.records.isEmpty)
    }
}

// MARK: - 启动

@Suite("启动耗时")
struct LaunchMonitorTests {
    @Test("时间线记录进程创建时刻，而不是设备开机时长")
    func recordsProcessStartNotSystemUptime() throws {
        let timeline = PerfLaunchTimeline.shared
        let processStart = try #require(timeline.processStartDate)

        // 上一版用 ProcessInfo.systemUptime 当冷启动起点，
        // 那是设备开机至今的时长，与本次进程何时启动毫无关系
        #expect(processStart < Date())
        #expect(Date().timeIntervalSince(processStart) < 86_400)
    }

    @Test("标记只保留首次，重复打点不覆盖")
    func keepsFirstMarkOnly() {
        let timeline = PerfLaunchTimeline.shared
        timeline.reset()

        timeline.mark("stage-a")
        let first = timeline.uptime(of: "stage-a")
        timeline.mark("stage-a")

        // 启动阶段按定义只发生一次；热启动时又走一遍不该覆盖冷启动数据
        #expect(timeline.uptime(of: "stage-a") == first)
        timeline.reset()
    }

    @Test("标记按时间排序")
    func sortsMarksByTime() {
        let timeline = PerfLaunchTimeline.shared
        timeline.reset()

        timeline.mark("first")
        timeline.mark("second")
        timeline.mark("third")

        #expect(timeline.allMarks().map(\.name) == ["first", "second", "third"])
        timeline.reset()
    }

    @Test("自定义启动阶段被上报，并带上相对上一阶段的耗时")
    func reportsCustomStages() async throws {
        let timeline = PerfLaunchTimeline.shared
        timeline.reset()
        timeline.mark("init-network")
        timeline.mark("load-db")

        let harness = MonitorHarness()
        var options = PerfLaunchMonitorOptions()
        options.explicitFirstFrameGracePeriod = .milliseconds(60)

        let monitor = PerfLaunchMonitor(options: options, context: harness.context, timeline: timeline)
        try await monitor.start()

        let stages = harness.payloads(of: PerfLaunchStageSample.self)
        #expect(stages.map(\.name) == ["init-network", "load-db"])
        #expect(stages[0].durationSincePreviousMs == nil)
        #expect(stages[1].durationSincePreviousMs != nil)

        await monitor.stop()
        timeline.reset()
    }

    @Test("显式标记首帧时，数据来源被标为 explicit")
    func prefersExplicitFirstFrame() async throws {
        let timeline = PerfLaunchTimeline.shared
        timeline.reset()
        PerfLaunchTimeline.markFirstFrame()

        let harness = MonitorHarness()
        var options = PerfLaunchMonitorOptions()
        options.explicitFirstFrameGracePeriod = .milliseconds(10)

        let monitor = PerfLaunchMonitor(options: options, context: harness.context, timeline: timeline)
        try await monitor.start()
        await monitor.reportColdLaunchIfNeeded()

        let sample = try #require(harness.payloads(of: PerfColdLaunchSample.self).first)
        #expect(sample.firstFrameSource == .explicit)
        #expect(sample.totalMs > 0)
        // 这个字段决定上面的数据有多可信：框架起得越晚，前期就有越长一段没被观测到
        #expect(sample.frameworkReadyMs > 0)

        await monitor.stop()
        timeline.reset()
    }

    @Test("冷启动只上报一次")
    func reportsColdLaunchOnce() async throws {
        let timeline = PerfLaunchTimeline.shared
        timeline.reset()
        PerfLaunchTimeline.markFirstFrame()

        let harness = MonitorHarness()
        let monitor = PerfLaunchMonitor(
            options: PerfLaunchMonitorOptions(),
            context: harness.context,
            timeline: timeline
        )
        try await monitor.start()

        await monitor.reportColdLaunchIfNeeded()
        await monitor.reportColdLaunchIfNeeded()
        await monitor.reportColdLaunchIfNeeded()

        #expect(harness.payloads(of: PerfColdLaunchSample.self).count == 1)

        await monitor.stop()
        timeline.reset()
    }
}
}
