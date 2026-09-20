import Foundation

/// 一次采样节拍。
public struct PerfTick: Sendable {
    /// 自调度器启动以来的节拍序号。
    public let sequence: UInt64
    public let uptimeNanos: UInt64
    public let date: Date

    public init(sequence: UInt64, uptimeNanos: UInt64, date: Date) {
        self.sequence = sequence
        self.uptimeNanos = uptimeNanos
        self.date = date
    }
}

/// 注册句柄，用于取消。
public struct PerfCadenceToken: Hashable, Sendable {
    let id: UInt64
}

/// 采样调度抽象。
///
/// 做成协议是为了让测试能注入手动调度器，不必真的等待定时器。
public protocol PerfScheduling: Sendable {
    /// 按固定周期回调。
    ///
    /// - Parameters:
    ///   - label: 用于诊断日志，通常是监测器 id。
    ///   - interval: 期望周期。实际周期会被对齐到调度器基频的整数倍。
    ///   - handler: 回调。上一次尚未执行完时，本次会被跳过而非排队。
    @discardableResult
    func schedule(
        label: String,
        interval: PerfDuration,
        handler: @escaping @Sendable (PerfTick) async -> Void
    ) -> PerfCadenceToken

    func cancel(_ token: PerfCadenceToken)
}

/// 生产环境的调度器：**单个**定时器驱动全部采样。
///
/// 上一版有 8 个各自独立的 `DispatchSourceTimer` 外加 1 个裸 `Thread` 死循环。
/// 每个定时器都会独立唤醒 CPU，在移动设备上直接影响电量与后台存活时长；
/// 定时器合并（timer coalescing）也无从谈起。
///
/// 这里用一个基频定时器（默认 100ms），各监测器按自己的周期分频。
public final class PerfScheduler: PerfScheduling, @unchecked Sendable {
    private struct Registration {
        let label: String
        /// 每隔多少个基频节拍触发一次。
        let divisor: UInt64
        let handler: @Sendable (PerfTick) async -> Void
        /// 上一次回调是否仍在执行。用于跳过而非堆积。
        var isRunning: Bool = false
        /// 因上一次未完成而被跳过的次数，用于诊断。
        var skipCount: UInt64 = 0
    }

    private let lock = PerfLock()
    private var registrations: [UInt64: Registration] = [:]
    private var nextTokenID: UInt64 = 1
    private var sequence: UInt64 = 0
    private var timer: DispatchSourceTimer?

    private let baseInterval: PerfDuration
    private let clock: any PerfClock
    private let log: PerfLog
    private let timerQueue: DispatchQueue

    public init(
        baseInterval: PerfDuration = .milliseconds(100),
        clock: any PerfClock = PerfSystemClock(),
        log: PerfLog = PerfLog(category: "scheduler")
    ) {
        precondition(baseInterval.nanoseconds > 0, "基频必须为正")
        self.baseInterval = baseInterval
        self.clock = clock
        self.log = log
        self.timerQueue = DispatchQueue(
            label: "com.performance.scheduler",
            qos: .utility
        )
    }

    deinit {
        timer?.cancel()
    }

    @discardableResult
    public func schedule(
        label: String,
        interval: PerfDuration,
        handler: @escaping @Sendable (PerfTick) async -> Void
    ) -> PerfCadenceToken {
        // 对齐到基频的整数倍，至少 1
        let ratio = Double(interval.nanoseconds) / Double(baseInterval.nanoseconds)
        let divisor = max(UInt64(1), UInt64(ratio.rounded()))

        if abs(ratio - Double(divisor)) > 0.01 {
            let actual = baseInterval * Double(divisor)
            log.debug("\(label) 请求周期 \(interval)，对齐到基频整数倍后为 \(actual)")
        }

        let token: PerfCadenceToken = lock.withLock {
            let id = nextTokenID
            nextTokenID &+= 1
            registrations[id] = Registration(label: label, divisor: divisor, handler: handler)
            return PerfCadenceToken(id: id)
        }

        startTimerIfNeeded()
        return token
    }

    public func cancel(_ token: PerfCadenceToken) {
        let shouldStop: Bool = lock.withLock {
            if let removed = registrations.removeValue(forKey: token.id), removed.skipCount > 0 {
                log.debug("\(removed.label) 注销，期间因上次未完成而跳过 \(removed.skipCount) 次")
            }
            return registrations.isEmpty
        }
        if shouldStop {
            stopTimer()
        }
    }

    /// 停止调度并清空所有注册。
    public func shutdown() {
        lock.withLock { registrations.removeAll() }
        stopTimer()
    }

    /// 因上一次回调未完成而被跳过的次数，按 label 汇总。诊断用。
    public func skipCounts() -> [String: UInt64] {
        lock.withLock {
            var result: [String: UInt64] = [:]
            for registration in registrations.values where registration.skipCount > 0 {
                result[registration.label, default: 0] += registration.skipCount
            }
            return result
        }
    }

    // MARK: - 定时器

    private func startTimerIfNeeded() {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        timer = source
        lock.unlock()

        source.schedule(
            deadline: .now() + baseInterval.timeInterval,
            repeating: baseInterval.timeInterval,
            // 允许 10% 的抖动，让系统有机会合并定时器唤醒以省电
            leeway: .nanoseconds(Int(baseInterval.nanoseconds / 10))
        )
        source.setEventHandler { [weak self] in
            self?.fire()
        }
        source.resume()
    }

    private func stopTimer() {
        let source: DispatchSourceTimer? = lock.withLock {
            let existing = timer
            timer = nil
            return existing
        }
        source?.cancel()
    }

    private func fire() {
        let tick = PerfTick(
            sequence: lock.withLock {
                sequence &+= 1
                return sequence
            },
            uptimeNanos: clock.uptimeNanos,
            date: clock.now
        )

        // 在锁内选出到期且空闲的注册并标记为运行中，锁外执行回调
        let due: [(id: UInt64, handler: @Sendable (PerfTick) async -> Void)] = lock.withLock {
            var result: [(UInt64, @Sendable (PerfTick) async -> Void)] = []
            for (id, registration) in registrations where tick.sequence % registration.divisor == 0 {
                guard !registration.isRunning else {
                    // 上一次还没跑完：跳过本次。
                    //
                    // 这正是上一版 ANR 检测的问题所在——watchdog 每 100ms 触发一次，
                    // 而每次要在同一队列上 `semaphore.wait(timeout: 4s)`。
                    // 主线程一旦真的卡住，后续 tick 全部排队积压，
                    // 卡顿结束后会集中爆发一批失效的检测。
                    registrations[id]?.skipCount &+= 1
                    continue
                }
                registrations[id]?.isRunning = true
                result.append((id, registration.handler))
            }
            return result
        }

        for item in due {
            Task(priority: .utility) { [weak self] in
                await item.handler(tick)
                self?.lock.withLock {
                    self?.registrations[item.id]?.isRunning = false
                }
            }
        }
    }
}

/// 手动驱动的调度器，供测试使用。
///
/// 让「模拟 30 秒的采样」变成 30 次同步调用，而不是真的等 30 秒。
public final class PerfManualScheduler: PerfScheduling, @unchecked Sendable {
    private struct Registration {
        let label: String
        let divisor: UInt64
        let handler: @Sendable (PerfTick) async -> Void
    }

    private let lock = PerfLock()
    private var registrations: [UInt64: Registration] = [:]
    private var nextTokenID: UInt64 = 1
    private var sequence: UInt64 = 0

    private let baseInterval: PerfDuration
    private let clock: PerfManualClock

    public init(baseInterval: PerfDuration = .milliseconds(100), clock: PerfManualClock) {
        self.baseInterval = baseInterval
        self.clock = clock
    }

    @discardableResult
    public func schedule(
        label: String,
        interval: PerfDuration,
        handler: @escaping @Sendable (PerfTick) async -> Void
    ) -> PerfCadenceToken {
        let ratio = Double(interval.nanoseconds) / Double(baseInterval.nanoseconds)
        let divisor = max(UInt64(1), UInt64(ratio.rounded()))
        return lock.withLock {
            let id = nextTokenID
            nextTokenID &+= 1
            registrations[id] = Registration(label: label, divisor: divisor, handler: handler)
            return PerfCadenceToken(id: id)
        }
    }

    public func cancel(_ token: PerfCadenceToken) {
        lock.withLock { _ = registrations.removeValue(forKey: token.id) }
    }

    /// 推进一个基频节拍，并等待所有到期回调执行完毕。
    public func tick() async {
        clock.advance(by: baseInterval)
        let current: UInt64 = lock.withLock {
            sequence &+= 1
            return sequence
        }
        let tick = PerfTick(sequence: current, uptimeNanos: clock.uptimeNanos, date: clock.now)

        let due = lock.withLock {
            registrations.values
                .filter { current % $0.divisor == 0 }
                .map(\.handler)
        }
        for handler in due {
            await handler(tick)
        }
    }

    /// 连续推进 `count` 个基频节拍。
    public func tick(times count: Int) async {
        for _ in 0..<count {
            await tick()
        }
    }
}
