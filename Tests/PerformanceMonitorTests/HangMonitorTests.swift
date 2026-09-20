import Foundation
import Testing

import PerformanceCore
@testable import PerformanceHang

@Suite("主线程健康监测")
struct HangMonitorTests {

    // MARK: - 忙闲追踪

    @Suite("忙闲追踪")
    struct MainThreadStateTrackerTests {
        @Test("被唤醒后标记为忙，休眠后标记为闲")
        func tracksBusyWindow() {
            let clock = PerfManualClock()
            let tracker = MainThreadStateTracker(clock: clock)

            #expect(tracker.snapshot().busySinceUptime == nil)

            tracker.simulateAfterWaiting()
            let busy = tracker.snapshot()
            #expect(busy.busySinceUptime != nil)
            #expect(busy.wakeupCount == 1)

            clock.advance(by: .milliseconds(300))
            tracker.simulateBeforeWaiting()
            #expect(tracker.snapshot().busySinceUptime == nil)
        }

        @Test("每次唤醒序号递增，用于区分「同一次卡顿」与「又卡了一次」")
        func incrementsWakeupCount() {
            let tracker = MainThreadStateTracker(clock: PerfManualClock())

            tracker.simulateAfterWaiting()
            tracker.simulateBeforeWaiting()
            tracker.simulateAfterWaiting()

            #expect(tracker.snapshot().wakeupCount == 2)
        }

        @Test("迭代结束时报出总耗时与阶段分解")
        func reportsIterationBreakdown() async {
            let clock = PerfManualClock()
            let tracker = MainThreadStateTracker(clock: clock)

            let collector = ResultCollector()
            tracker.setIterationHandler { result in
                Task { await collector.add(result) }
            }

            tracker.simulateAfterWaiting()
            clock.advance(by: .milliseconds(10))
            tracker.simulateBeforeTimers()
            clock.advance(by: .milliseconds(30))
            tracker.simulateBeforeSources()
            clock.advance(by: .milliseconds(60))
            tracker.simulateBeforeWaiting()

            try? await Task.sleep(nanoseconds: 50_000_000)
            let results = await collector.results
            let result = try! #require(results.first)

            #expect(result.totalNanos == PerfDuration.milliseconds(100).nanoseconds)
            #expect(result.timersNanos == PerfDuration.milliseconds(30).nanoseconds)
            #expect(result.sourcesNanos == PerfDuration.milliseconds(60).nanoseconds)
        }

        private actor ResultCollector {
            private(set) var results: [MainThreadStateTracker.IterationResult] = []
            func add(_ result: MainThreadStateTracker.IterationResult) { results.append(result) }
        }
    }

    // MARK: - 卡顿判定

    /// 已启动的监测器及其追踪器。
    ///
    /// 必须整体持有：调度器闭包对监测器是**弱引用**（生产环境由
    /// `PerfCenter` 持有，弱引用避免循环），
    /// 测试里一旦只留下 tracker 而丢掉 monitor，actor 会立刻释放，
    /// watchdog 随之变成空操作，所有断言都会得到空数据。
    struct StartedMonitor {
        let monitor: PerfHangMonitor
        let tracker: MainThreadStateTracker
    }

    /// 造一个用「不挂真实 RunLoop observer」的追踪器驱动的监测器，并启动它。
    ///
    /// 测试用 `simulate*` 直接驱动主线程忙闲状态机。
    private func makeStartedMonitor(
        harness: MonitorHarness,
        configure: (inout PerfHangMonitorOptions) -> Void = { _ in }
    ) async throws -> StartedMonitor {
        var options = PerfHangMonitorOptions()
        options.checkInterval = .milliseconds(100)
        options.unresponsiveThreshold = .seconds(2)
        options.severeThreshold = .seconds(8)
        options.tracksQueueLatency = false      // 需要真实主队列，单测里关掉
        configure(&options)

        let monitor = PerfHangMonitor(options: options, context: harness.context) { clock in
            MainThreadStateTracker(clock: clock, installsRunLoopObserver: false)
        }
        try await monitor.start()
        let tracker = try #require(await monitor.currentTracker)
        return StartedMonitor(monitor: monitor, tracker: tracker)
    }

    @Test("主线程持续无响应超过阈值时上报 ANR")
    func detectsUnresponsiveMainThread() async throws {
        let harness = MonitorHarness()
        let started = try await makeStartedMonitor(harness: harness)

        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 25)   // 推进 2.5 秒

        let hangs = harness.payloads(of: PerfHangEvent.self)
        let hang = try #require(hangs.first)

        #expect(hang.stage == .unresponsive)
        #expect(hang.durationMs >= 2_000)
        // 关键：上报时主线程还卡着，因此堆栈是真正的现场
        #expect(hang.isOngoing)
        withExtendedLifetime(started) {}
    }

    @Test("同一次卡顿每个级别只报一次，不会被检查周期刷屏")
    func reportsEachStageOnce() async throws {
        let harness = MonitorHarness()
        let started = try await makeStartedMonitor(harness: harness)

        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 100)   // 卡满 10 秒

        let hangs = harness.payloads(of: PerfHangEvent.self)
        // 10 秒 / 100ms 检查周期 = 100 次检查，但只该产出
        // unresponsive 与 severe 各一条
        #expect(hangs.count == 2)
        #expect(hangs.map(\.stage) == [.unresponsive, .severe])
        withExtendedLifetime(started) {}
    }

    @Test("卡顿时长超过严重阈值后升级")
    func escalatesToSevere() async throws {
        let harness = MonitorHarness()
        let started = try await makeStartedMonitor(harness: harness)

        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 90)

        let severe = harness.records(ofKind: PerfHangEvent.kind)
            .first { $0.severity == .critical }
        #expect(severe != nil)
        withExtendedLifetime(started) {}
    }

    @Test("主线程恢复后状态重置，下一次卡顿重新计数")
    func resetsAfterRecovery() async throws {
        let harness = MonitorHarness()
        let started = try await makeStartedMonitor(harness: harness)

        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 25)
        started.tracker.simulateBeforeWaiting()
        await harness.scheduler.tick(times: 5)

        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 25)

        // 两次独立的卡顿，各报一条
        #expect(harness.payloads(of: PerfHangEvent.self).count == 2)
        withExtendedLifetime(started) {}
    }

    @Test("短于阈值的忙碌不上报")
    func ignoresShortBusyWindows() async throws {
        let harness = MonitorHarness()
        let started = try await makeStartedMonitor(harness: harness)

        for _ in 0..<10 {
            started.tracker.simulateAfterWaiting()
            await harness.scheduler.tick(times: 5)   // 每次只忙 500ms
            started.tracker.simulateBeforeWaiting()
        }

        #expect(harness.payloads(of: PerfHangEvent.self).isEmpty)
        withExtendedLifetime(started) {}
    }

    @Test("卡顿的时间戳是开始时刻，不是发现时刻")
    func stampsHangAtStartTime() async throws {
        let harness = MonitorHarness()
        let started = try await makeStartedMonitor(harness: harness)

        let startUptime = harness.clock.uptimeNanos
        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 25)

        let record = try #require(harness.records(ofKind: PerfHangEvent.kind).first)
        // 否则时间线上会出现 2 秒错位，与同期的 CPU/内存采样对不上
        #expect(record.uptimeNanos == startUptime)
        withExtendedLifetime(started) {}
    }

    // MARK: - 死锁

    @Test("寄存器连续不变时判定为死锁")
    func detectsDeadlockWhenRegistersFrozen() async throws {
        let backtrace = FakeBacktraceProvider()
        // 每次采样都返回同一个 PC —— 线程确实停在原地
        backtrace.enqueue(Array(repeating: FakeBacktraceProvider.makeSnapshot(pc: 0xDEAD), count: 50))

        let harness = MonitorHarness(backtrace: backtrace)
        let started = try await makeStartedMonitor(harness: harness) {
            $0.deadlockUnchangedSampleCount = 3
        }

        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 40)

        let deadlocks = harness.payloads(of: PerfDeadlockEvent.self)
        let deadlock = try #require(deadlocks.first)

        #expect(deadlock.unchangedSampleCount >= 3)
        #expect(deadlock.registers.programCounter == 0xDEAD)
        // 死锁涉及至少两方，只看主线程不知道锁被谁持有
        #expect(deadlock.allThreadStacks != nil)
        withExtendedLifetime(started) {}
    }

    @Test("寄存器持续变化时不判定为死锁——那只是跑得慢")
    func doesNotReportDeadlockWhenProgressing() async throws {
        let backtrace = FakeBacktraceProvider()
        // PC 每次都在变：线程在推进，只是慢
        backtrace.enqueue((0..<50).map { FakeBacktraceProvider.makeSnapshot(pc: 0x1000 + UInt64($0) * 0x10) })

        let harness = MonitorHarness(backtrace: backtrace)
        let started = try await makeStartedMonitor(harness: harness) {
            $0.deadlockUnchangedSampleCount = 3
        }

        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 40)

        // 只看耗时无法区分死锁与慢；寄存器是否变化才是判据
        #expect(harness.payloads(of: PerfDeadlockEvent.self).isEmpty)
        #expect(!harness.payloads(of: PerfHangEvent.self).isEmpty)
        withExtendedLifetime(started) {}
    }

    @Test("死锁只报一次")
    func reportsDeadlockOnce() async throws {
        let backtrace = FakeBacktraceProvider()
        backtrace.enqueue(Array(repeating: FakeBacktraceProvider.makeSnapshot(pc: 0xBEEF), count: 100))

        let harness = MonitorHarness(backtrace: backtrace)
        let started = try await makeStartedMonitor(harness: harness) {
            $0.deadlockUnchangedSampleCount = 2
        }

        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 100)

        #expect(harness.payloads(of: PerfDeadlockEvent.self).count == 1)
        withExtendedLifetime(started) {}
    }

    @Test("没有回溯能力时降级为只报 ANR，不崩溃")
    func degradesGracefullyWithoutBacktrace() async throws {
        let harness = MonitorHarness(backtrace: nil)
        let started = try await makeStartedMonitor(harness: harness)

        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 30)

        let hang = try #require(harness.payloads(of: PerfHangEvent.self).first)
        #expect(hang.mainThreadStack == nil)
        #expect(harness.payloads(of: PerfDeadlockEvent.self).isEmpty)
        withExtendedLifetime(started) {}
    }

    @Test("过长的堆栈被截断")
    func truncatesLongStacks() async throws {
        let backtrace = FakeBacktraceProvider(
            defaultSnapshot: FakeBacktraceProvider.makeSnapshot(pc: 0x2000, frameCount: 120)
        )
        let harness = MonitorHarness(backtrace: backtrace)
        let started = try await makeStartedMonitor(harness: harness) { $0.maxStackFrames = 20 }

        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 25)

        let stack = try #require(harness.payloads(of: PerfHangEvent.self).first?.mainThreadStack)
        #expect(stack.frames.count == 20)
        #expect(stack.isTruncated)
        withExtendedLifetime(started) {}
    }

    @Test("截断不影响聚合签名")
    func truncationPreservesSignature() async throws {
        let full = FakeBacktraceProvider.makeSnapshot(pc: 0x3000, frameCount: 120)
        let backtrace = FakeBacktraceProvider(defaultSnapshot: full)
        let harness = MonitorHarness(backtrace: backtrace)
        let started = try await makeStartedMonitor(harness: harness) { $0.maxStackFrames = 10 }

        started.tracker.simulateAfterWaiting()
        await harness.scheduler.tick(times: 25)

        let hang = try #require(harness.payloads(of: PerfHangEvent.self).first)
        // 签名按完整帧列表算，否则改一下截断长度就会让历史数据无法聚合
        #expect(hang.stackSignature == full.signature)
        withExtendedLifetime(started) {}
    }

    @Test("停止后不再检查")
    func stopsCleanly() async throws {
        let harness = MonitorHarness()
        let started = try await makeStartedMonitor(harness: harness)

        started.tracker.simulateAfterWaiting()
        await started.monitor.stop()
        harness.sink.reset()

        await harness.scheduler.tick(times: 50)
        #expect(harness.sink.records.isEmpty)
        withExtendedLifetime(started) {}
    }
}
