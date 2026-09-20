import Foundation
import Testing

@testable import PerformanceCore

// MARK: - 缓冲

@Suite("PerfRecordBuffer")
struct PerfRecordBufferTests {
    private func makeRecord(_ value: Double) -> PerfAnyRecord {
        PerfAnyRecord(
            timestamp: Date(timeIntervalSince1970: value),
            uptimeNanos: UInt64(value),
            sessionID: PerfSessionID(rawValue: "test"),
            severity: .info,
            thread: nil,
            kind: SampleMetric.kind,
            schemaVersion: SampleMetric.schemaVersion,
            payload: SampleMetric(value: value, label: "x", counts: [])
        )
    }

    @Test("drain 取走全部记录并清空缓冲")
    func drainsAndClears() {
        let buffer = PerfRecordBuffer(capacity: 10)
        for i in 0..<5 { buffer.submit(makeRecord(Double(i))) }
        #expect(buffer.count == 5)

        let drained = buffer.drain()
        #expect(drained.records.count == 5)
        #expect(drained.dropped == 0)
        #expect(buffer.count == 0)

        // 第二次 drain 应为空，而不是重复给出同一批数据
        #expect(buffer.drain().records.isEmpty)
    }

    @Test("容量满后丢弃新记录并计数，已入队的不受影响")
    func dropsWhenFull() {
        let buffer = PerfRecordBuffer(capacity: 3)
        #expect(buffer.submit(makeRecord(0)) == true)
        #expect(buffer.submit(makeRecord(1)) == true)
        #expect(buffer.submit(makeRecord(2)) == true)
        #expect(buffer.submit(makeRecord(3)) == false)
        #expect(buffer.submit(makeRecord(4)) == false)

        let drained = buffer.drain()
        #expect(drained.records.count == 3)
        #expect(drained.dropped == 2)
        #expect(drained.droppedCumulative == 2)

        // 丢弃的窗口计数在 drain 后归零，累计值保留
        buffer.submit(makeRecord(5))
        let second = buffer.drain()
        #expect(second.dropped == 0)
        #expect(second.droppedCumulative == 2)
    }

    @Test("drain 让出空间后可以继续写入")
    func recoversAfterDrain() {
        let buffer = PerfRecordBuffer(capacity: 2)
        buffer.submit(makeRecord(0))
        buffer.submit(makeRecord(1))
        #expect(buffer.submit(makeRecord(2)) == false)

        _ = buffer.drain()
        #expect(buffer.submit(makeRecord(3)) == true)
        #expect(buffer.count == 1)
    }

    @Test("多线程并发提交不丢数据、不重复")
    func isSafeUnderConcurrency() async {
        let threadCount = 8
        let perThread = 500
        let buffer = PerfRecordBuffer(capacity: threadCount * perThread)

        await withTaskGroup(of: Void.self) { group in
            for thread in 0..<threadCount {
                group.addTask {
                    for i in 0..<perThread {
                        buffer.submit(makeRecordStatic(Double(thread * perThread + i)))
                    }
                }
            }
        }

        let drained = buffer.drain()
        #expect(drained.records.count == threadCount * perThread)
        #expect(drained.dropped == 0)

        // 每个值恰好出现一次
        let values = Set(drained.records.compactMap { $0.payload(as: SampleMetric.self)?.value })
        #expect(values.count == threadCount * perThread)
    }
}

/// 供并发测试在 `@Sendable` 闭包里调用。
private func makeRecordStatic(_ value: Double) -> PerfAnyRecord {
    PerfAnyRecord(
        timestamp: Date(timeIntervalSince1970: value),
        uptimeNanos: UInt64(value),
        sessionID: PerfSessionID(rawValue: "test"),
        severity: .info,
        thread: nil,
        kind: SampleMetric.kind,
        schemaVersion: SampleMetric.schemaVersion,
        payload: SampleMetric(value: value, label: "x", counts: [])
    )
}

// MARK: - 时钟

@Suite("PerfManualClock")
struct PerfClockTests {
    @Test("推进同时影响单调时钟与墙上时钟")
    func advancesBothClocks() {
        let clock = PerfManualClock(uptimeNanos: 0, now: Date(timeIntervalSince1970: 1_000))
        clock.advance(by: .seconds(2.5))

        #expect(clock.uptimeNanos == 2_500_000_000)
        #expect(clock.now.timeIntervalSince1970 == 1_002.5)
    }

    @Test("墙上时钟被回拨不影响单调时钟的间隔计算")
    func monotonicSurvivesWallClockSkew() {
        let clock = PerfManualClock(uptimeNanos: 0, now: Date(timeIntervalSince1970: 1_000))
        let start = clock.uptimeNanos

        clock.advance(by: .seconds(5))
        clock.skewWallClock(by: -3_600)   // 模拟 NTP 把时间往回校正一小时

        // 墙上时钟算出来的间隔是负的，单调时钟不受影响
        #expect(clock.now.timeIntervalSince1970 < 1_000)
        #expect(clock.elapsed(since: start) == .seconds(5))
    }
}

// MARK: - 调度

@Suite("PerfManualScheduler")
struct PerfSchedulerTests {
    @Test("按周期分频：1 秒的注册在 100ms 基频下每 10 拍触发一次")
    func dividesCadence() async {
        let clock = PerfManualClock()
        let scheduler = PerfManualScheduler(baseInterval: .milliseconds(100), clock: clock)

        let counter = Counter()
        scheduler.schedule(label: "every-second", interval: .seconds(1)) { _ in
            await counter.increment()
        }

        await scheduler.tick(times: 25)
        #expect(await counter.value == 2)   // 第 10、20 拍
    }

    @Test("不同周期的注册各自独立计数")
    func handlesMixedCadences() async {
        let clock = PerfManualClock()
        let scheduler = PerfManualScheduler(baseInterval: .milliseconds(100), clock: clock)

        let fast = Counter()
        let slow = Counter()
        scheduler.schedule(label: "fast", interval: .milliseconds(100)) { _ in await fast.increment() }
        scheduler.schedule(label: "slow", interval: .milliseconds(500)) { _ in await slow.increment() }

        await scheduler.tick(times: 10)
        #expect(await fast.value == 10)
        #expect(await slow.value == 2)
    }

    @Test("取消后不再回调")
    func stopsAfterCancel() async {
        let clock = PerfManualClock()
        let scheduler = PerfManualScheduler(baseInterval: .milliseconds(100), clock: clock)

        let counter = Counter()
        let token = scheduler.schedule(label: "x", interval: .milliseconds(100)) { _ in
            await counter.increment()
        }

        await scheduler.tick(times: 3)
        scheduler.cancel(token)
        await scheduler.tick(times: 5)

        #expect(await counter.value == 3)
    }

    @Test("短于基频的周期被提升到基频，而不是静默永不触发")
    func clampsSubBaseInterval() async {
        let clock = PerfManualClock()
        let scheduler = PerfManualScheduler(baseInterval: .milliseconds(100), clock: clock)

        let counter = Counter()
        scheduler.schedule(label: "too-fast", interval: .milliseconds(10)) { _ in
            await counter.increment()
        }

        await scheduler.tick(times: 4)
        #expect(await counter.value == 4)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

// MARK: - Sink

@Suite("PerfCollectingSink")
struct PerfEventSinkTests {
    @Test("按类型取出载荷，不匹配的被跳过")
    func filtersPayloadsByType() {
        let sink = PerfCollectingSink()
        let recorder = PerfRecorder(
            sink: sink,
            sessionID: PerfSessionID(rawValue: "s"),
            clock: PerfManualClock()
        )

        recorder.record(SampleMetric(value: 1, label: "a", counts: []))
        recorder.record(OtherMetric(flag: true))
        recorder.record(SampleMetric(value: 2, label: "b", counts: []))

        #expect(sink.records.count == 3)
        #expect(sink.payloads(of: SampleMetric.self).map(\.value) == [1, 2])
        #expect(sink.records(ofKind: OtherMetric.kind).count == 1)
    }

    @Test("recorder 用注入的时钟打时间戳，而不是系统时间")
    func stampsFromInjectedClock() {
        let clock = PerfManualClock(uptimeNanos: 500, now: Date(timeIntervalSince1970: 12_345))
        let sink = PerfCollectingSink()
        let recorder = PerfRecorder(sink: sink, sessionID: PerfSessionID(rawValue: "s"), clock: clock)

        recorder.record(OtherMetric(flag: true), severity: .critical, thread: .main)

        let record = try! #require(sink.records.first)
        #expect(record.uptimeNanos == 500)
        #expect(record.timestamp.timeIntervalSince1970 == 12_345)
        #expect(record.severity == .critical)
        #expect(record.thread?.isMain == true)
    }

    @Test("可显式指定时间，用于「事件发生在过去、现在才处理完」的场景")
    func acceptsExplicitTimestamp() {
        let clock = PerfManualClock(uptimeNanos: 9_000, now: Date(timeIntervalSince1970: 900))
        let sink = PerfCollectingSink()
        let recorder = PerfRecorder(sink: sink, sessionID: PerfSessionID(rawValue: "s"), clock: clock)

        // 卡顿在 T0 开始，堆栈到 T0+3s 才抓完，记录应以 T0 为准
        recorder.record(
            OtherMetric(flag: true),
            timestamp: Date(timeIntervalSince1970: 897),
            uptimeNanos: 6_000
        )

        let record = try! #require(sink.records.first)
        #expect(record.uptimeNanos == 6_000)
        #expect(record.timestamp.timeIntervalSince1970 == 897)
    }
}
