import Foundation

import PerformanceCore

/// 每个用例一套独立的假依赖。
///
/// 有了它，「模拟 30 秒采样」是 300 次同步调用而不是真的等 30 秒。
/// 上一版唯一的真测试用 `Thread.sleep(5)` 阻塞主线程，单次跑 10 秒以上，
/// 于是 15 个模块里 14 个零覆盖。
struct MonitorHarness {
    let clock: PerfManualClock
    let scheduler: PerfManualScheduler
    let sink: PerfCollectingSink
    let lifecycle: PerfManualAppLifecycle
    let context: PerfMonitorContext

    init(
        baseInterval: PerfDuration = .milliseconds(100),
        backtrace: (any PerfBacktraceProviding)? = nil
    ) {
        let clock = PerfManualClock()
        let scheduler = PerfManualScheduler(baseInterval: baseInterval, clock: clock)
        let sink = PerfCollectingSink()
        let lifecycle = PerfManualAppLifecycle()

        self.clock = clock
        self.scheduler = scheduler
        self.sink = sink
        self.lifecycle = lifecycle
        self.context = PerfMonitorContext(
            recorder: PerfRecorder(
                sink: sink,
                sessionID: PerfSessionID(rawValue: "20260920T120000-TEST01"),
                clock: clock
            ),
            scheduler: scheduler,
            clock: clock,
            log: .disabled,
            backtrace: backtrace,
            lifecycle: lifecycle
        )
    }

    func payloads<P: PerfPayload>(of type: P.Type) -> [P] {
        sink.payloads(of: type)
    }

    func records(ofKind kind: PerfKind) -> [PerfAnyRecord] {
        sink.records(ofKind: kind)
    }
}

/// 可编排的假栈回溯，用于验证卡顿/死锁判定逻辑。
final class FakeBacktraceProvider: PerfBacktraceProviding, @unchecked Sendable {
    private let lock = PerfLock()
    private var queuedSnapshots: [PerfThreadSnapshot] = []
    private var defaultSnapshot: PerfThreadSnapshot
    private(set) var snapshotCallCount = 0
    private(set) var allThreadsCallCount = 0

    init(defaultSnapshot: PerfThreadSnapshot = FakeBacktraceProvider.makeSnapshot(pc: 0x1000)) {
        self.defaultSnapshot = defaultSnapshot
    }

    /// 依次返回排队的快照，用完后回落到默认快照。
    func enqueue(_ snapshots: [PerfThreadSnapshot]) {
        lock.withLock { queuedSnapshots.append(contentsOf: snapshots) }
    }

    func snapshot(of thread: PerfThreadHandle) throws -> PerfThreadSnapshot {
        lock.withLock {
            snapshotCallCount += 1
            return queuedSnapshots.isEmpty ? defaultSnapshot : queuedSnapshots.removeFirst()
        }
    }

    func snapshotMainThread() throws -> PerfThreadSnapshot {
        try snapshot(of: PerfThreadHandle(machPort: 1))
    }

    func snapshotAllThreads() throws -> [PerfThreadSnapshot] {
        lock.withLock { allThreadsCallCount += 1 }
        return [try snapshotMainThread()]
    }

    func binaryImages() -> [PerfBinaryImage] {
        [
            PerfBinaryImage(
                name: "TestApp",
                path: "/tmp/TestApp",
                loadAddress: 0x1_0000_0000,
                slide: 0,
                uuid: String(repeating: "A", count: 32),
                architecture: "arm64"
            )
        ]
    }

    /// 构造一份指定 PC 的假快照。PC 相同即视为「线程停在原地」。
    static func makeSnapshot(pc: UInt64, frameCount: Int = 3) -> PerfThreadSnapshot {
        let frames = (0..<frameCount).map { index in
            PerfFrame(
                address: pc + UInt64(index * 0x100),
                imageName: "TestApp",
                imageOffset: pc + UInt64(index * 0x100) - 0x1000,
                symbol: "frame\(index)"
            )
        }
        return PerfThreadSnapshot(
            thread: .main,
            frames: frames,
            registers: PerfRegisters(
                programCounter: pc,
                linkRegister: pc + 4,
                stackPointer: 0x7000,
                framePointer: 0x7100
            ),
            isTruncated: false,
            signature: PerfThreadSnapshot.computeSignature(frames: frames)
        )
    }
}
