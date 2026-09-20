import Foundation
import Testing

import PerformanceCore
@testable import PerformanceRendering

@Suite("渲染监测")
struct RenderingMonitorTests {
    private func makeMonitor(
        harness: MonitorHarness,
        link: PerfManualDisplayLink,
        configure: (inout PerfRenderingMonitorOptions) -> Void = { _ in }
    ) -> PerfRenderingMonitor {
        var options = PerfRenderingMonitorOptions()
        options.windowInterval = .seconds(1)
        configure(&options)
        return PerfRenderingMonitor(options: options, context: harness.context) { _ in link }
    }

    /// 以 60Hz 推进若干帧。
    private func advance(_ link: PerfManualDisplayLink, frames: Int, frameMs: Double = 1000.0 / 60) {
        for _ in 0..<frames {
            link.advance(by: frameMs / 1_000, targetInterval: 1.0 / 60)
        }
    }

    @Test("稳定 60 帧时算出的帧率接近 60，且没有掉帧")
    func reportsSteadyFrameRate() async throws {
        let harness = MonitorHarness()
        let link = PerfManualDisplayLink()
        let monitor = makeMonitor(harness: harness, link: link)

        try await monitor.start()
        advance(link, frames: 61)          // 首帧建立基线，之后 60 帧
        await harness.scheduler.tick(times: 10)   // 推进到 1 秒窗口

        let samples = harness.payloads(of: PerfFPSSample.self)
        let sample = try #require(samples.first)

        #expect(abs(sample.fps - 60) < 1)
        #expect(abs(sample.targetFPS - 60) < 1)
        #expect(sample.jankFrameCount == 0)
        #expect(sample.hitchTimeRatio < 0.05)
    }

    @Test("单帧超时触发掉帧事件")
    func detectsJank() async throws {
        let harness = MonitorHarness()
        let link = PerfManualDisplayLink()
        let monitor = makeMonitor(harness: harness, link: link)

        try await monitor.start()
        advance(link, frames: 10)
        link.advance(by: 0.2, targetInterval: 1.0 / 60)   // 卡了 200ms
        advance(link, frames: 10)

        let janks = harness.payloads(of: PerfJankEvent.self)
        #expect(janks.count == 1)

        let jank = try #require(janks.first)
        #expect(abs(jank.frameMs - 200) < 1)
        // 200ms / 16.67ms ≈ 12 帧，减去本该有的那一帧
        #expect(jank.droppedFrames >= 10)
    }

    @Test("掉帧倍数阈值可调，不会把正常抖动误报成掉帧")
    func respectsJankThreshold() async throws {
        let harness = MonitorHarness()
        let link = PerfManualDisplayLink()
        let monitor = makeMonitor(harness: harness, link: link) {
            $0.jankThresholdMultiplier = 3.0
        }

        try await monitor.start()
        advance(link, frames: 5)
        // 2.5 倍：超过默认的 2.0，但没到这里设的 3.0
        link.advance(by: 2.5 / 60, targetInterval: 1.0 / 60)

        #expect(harness.payloads(of: PerfJankEvent.self).isEmpty)
    }

    @Test("掉帧事件在单个窗口内被限流")
    func throttlesJankEvents() async throws {
        let harness = MonitorHarness()
        let link = PerfManualDisplayLink()
        let monitor = makeMonitor(harness: harness, link: link) {
            $0.maxJankEventsPerWindow = 3
        }

        try await monitor.start()
        link.advance(by: 1.0 / 60, targetInterval: 1.0 / 60)   // 基线
        for _ in 0..<20 {
            link.advance(by: 0.1, targetInterval: 1.0 / 60)
        }

        // 滚动列表时掉帧可能极密集，逐帧记录会瞬间灌满缓冲、挤掉其他数据
        #expect(harness.payloads(of: PerfJankEvent.self).count == 3)
    }

    @Test("限流不影响窗口聚合里的掉帧总数")
    func aggregateCountsAllJanks() async throws {
        let harness = MonitorHarness()
        let link = PerfManualDisplayLink()
        let monitor = makeMonitor(harness: harness, link: link) {
            $0.maxJankEventsPerWindow = 2
        }

        try await monitor.start()
        link.advance(by: 1.0 / 60, targetInterval: 1.0 / 60)
        for _ in 0..<10 {
            link.advance(by: 0.05, targetInterval: 1.0 / 60)
        }
        await harness.scheduler.tick(times: 10)

        let sample = try #require(harness.payloads(of: PerfFPSSample.self).first)
        #expect(sample.jankFrameCount == 10)
    }

    @Test("目标帧率跟随屏幕，不假定 60Hz")
    func adaptsToTargetRefreshRate() async throws {
        let harness = MonitorHarness()
        let link = PerfManualDisplayLink()
        let monitor = makeMonitor(harness: harness, link: link)

        try await monitor.start()
        // 120Hz 设备上稳定跑满
        for _ in 0..<121 {
            link.advance(by: 1.0 / 120, targetInterval: 1.0 / 120)
        }
        await harness.scheduler.tick(times: 10)

        let sample = try #require(harness.payloads(of: PerfFPSSample.self).first)
        #expect(abs(sample.targetFPS - 120) < 2)
        #expect(abs(sample.fps - 120) < 2)
        // 上一版把目标帧率当常量 60，这里会把满帧的 120Hz 误判成「超速」并算出掉帧
        #expect(sample.jankFrameCount == 0)
    }

    @Test("帧率相对目标值定级，而不是用绝对阈值")
    func severityIsRelativeToTarget() async throws {
        let harness = MonitorHarness()
        let link = PerfManualDisplayLink()
        let monitor = makeMonitor(harness: harness, link: link)

        try await monitor.start()
        // 120Hz 屏幕上只跑到 50fps —— 绝对值看着还行，相对目标已经很差
        for _ in 0..<51 {
            link.advance(by: 1.0 / 50, targetInterval: 1.0 / 120)
        }
        await harness.scheduler.tick(times: 10)

        let record = try #require(harness.records(ofKind: PerfFPSSample.kind).first)
        #expect(record.severity >= .warning)
    }

    @Test("卡顿时间占比能反映出「帧率尚可但有明显顿挫」")
    func hitchRatioCapturesSingleLongStall() async throws {
        let harness = MonitorHarness()
        let link = PerfManualDisplayLink()
        let monitor = makeMonitor(harness: harness, link: link)

        try await monitor.start()
        link.advance(by: 1.0 / 60, targetInterval: 1.0 / 60)
        advance(link, frames: 59)
        link.advance(by: 0.5, targetInterval: 1.0 / 60)   // 一次 500ms 的顿挫
        await harness.scheduler.tick(times: 10)

        let sample = try #require(harness.payloads(of: PerfFPSSample.self).first)
        // 60 帧里只卡了 1 帧，FPS 看起来还不错
        #expect(sample.fps > 40)
        // 但卡顿时间占了将近三分之一，用户是明确能感觉到的
        #expect(sample.hitchTimeRatio > 0.25)
        #expect(abs(sample.worstFrameMs - 500) < 5)
    }

    @Test("app 切后台再回来的巨大时间间隔被丢弃，不会被记成一次超长卡顿")
    func discardsImplausibleFrameGaps() async throws {
        let harness = MonitorHarness()
        let link = PerfManualDisplayLink()
        let monitor = makeMonitor(harness: harness, link: link)

        try await monitor.start()
        advance(link, frames: 5)
        link.advance(by: 30, targetInterval: 1.0 / 60)   // 后台待了 30 秒
        advance(link, frames: 5)
        await harness.scheduler.tick(times: 10)

        #expect(harness.payloads(of: PerfJankEvent.self).isEmpty)

        let sample = try #require(harness.payloads(of: PerfFPSSample.self).first)
        #expect(sample.worstFrameMs < 100)
    }

    @Test("停止后不再产生数据")
    func stopsCleanly() async throws {
        let harness = MonitorHarness()
        let link = PerfManualDisplayLink()
        let monitor = makeMonitor(harness: harness, link: link)

        try await monitor.start()
        advance(link, frames: 10)
        await monitor.stop()

        harness.sink.reset()
        link.advance(by: 0.5, targetInterval: 1.0 / 60)
        await harness.scheduler.tick(times: 10)

        #expect(harness.sink.records.isEmpty)
    }

    @Test("窗口边界不会吞掉一帧")
    func doesNotDropFramesAtWindowBoundary() async throws {
        let harness = MonitorHarness()
        let link = PerfManualDisplayLink()
        let monitor = makeMonitor(harness: harness, link: link)

        try await monitor.start()
        link.advance(by: 1.0 / 60, targetInterval: 1.0 / 60)   // 基线

        for _ in 0..<3 {
            advance(link, frames: 60)
            await harness.scheduler.tick(times: 10)
        }

        let samples = harness.payloads(of: PerfFPSSample.self)
        #expect(samples.count == 3)
        // 每个窗口都应该收满 60 帧；若窗口边界重置了「上一帧时间戳」，
        // 每个窗口都会少一帧
        #expect(samples.allSatisfy { $0.frameCount == 60 })
    }
}
