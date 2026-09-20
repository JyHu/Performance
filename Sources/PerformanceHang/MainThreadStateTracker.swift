import CoreFoundation
import Foundation
import PerformanceCore

/// 主线程忙闲状态的追踪器。
///
/// ## 核心设计：watchdog 不向主队列投递任何东西
///
/// 常见的 ANR 检测做法是「后台定时往主队列扔一个信号量，测它多久被处理」——
/// 上一版就是这么做的，而且**做了两遍**（ANR 检测器和死锁检测器各一套），
/// 主线程被两路互不知情的探针同时打扰。
///
/// 这里换了个方向：让主线程的 RunLoop observer 在被唤醒时记一个时间戳、
/// 进入休眠时清掉，watchdog 只需要**读**这个时间戳。
///
/// 好处是实质性的：
/// - 主线程零额外负担，不会出现「检测卡顿的探针自己加剧了卡顿」。
/// - 卡顿还在进行时就能发现，因而能抓到**真正的现场堆栈**；
///   靠投递探针的方案只能在主线程恢复后才知道刚才卡过，那时堆栈已经没用了。
/// - 主队列积压严重时，投递式探针自己也会排队，测出的时间是失真的。
final class MainThreadStateTracker: @unchecked Sendable {
    /// 主线程当前的忙闲快照。
    struct BusySnapshot {
        /// 本次工作开始的单调时间。nil 表示主线程正在休眠。
        let busySinceUptime: UInt64?
        /// 本次工作对应的 RunLoop 模式。
        let mode: String?
        /// 自进程启动以来主线程被唤醒的次数，用于区分「同一次卡顿」与「又卡了一次」。
        let wakeupCount: UInt64
    }

    private let lock = PerfLock()
    private let clock: any PerfClock

    private var busySinceUptime: UInt64?
    private var currentMode: String?
    private var wakeupCount: UInt64 = 0

    /// 本次迭代内各阶段的时间戳，用于阶段分解。
    private var afterWaitingUptime: UInt64?
    private var beforeTimersUptime: UInt64?
    private var beforeSourcesUptime: UInt64?

    private var observer: CFRunLoopObserver?

    /// 是否真的往主 RunLoop 上挂 observer。
    ///
    /// 测试里置为 false，改由 `simulate*` 方法驱动状态机。
    /// 这样被测的仍是**同一份**忙闲判定逻辑，而不是另写一个假实现——
    /// 假实现测过了不代表真实现是对的。
    private let installsRunLoopObserver: Bool

    /// 单次迭代结束时的回调，在**主线程**上同步执行。
    private var onIterationEnd: (@Sendable (IterationResult) -> Void)?

    struct IterationResult {
        let totalNanos: UInt64
        let timersNanos: UInt64
        let sourcesNanos: UInt64
        let mode: String?
    }

    init(clock: any PerfClock, installsRunLoopObserver: Bool = true) {
        self.clock = clock
        self.installsRunLoopObserver = installsRunLoopObserver
    }

    deinit {
        removeObserver()
    }

    // MARK: - 安装

    /// 在主 RunLoop 上安装 observer。
    ///
    /// - Parameter tracksPhases: 是否额外监听 timer/source 分界，做阶段分解。
    func install(
        tracksPhases: Bool,
        onIterationEnd: @escaping @Sendable (IterationResult) -> Void
    ) {
        lock.withLock { self.onIterationEnd = onIterationEnd }

        let activities: CFRunLoopActivity = tracksPhases
            ? [.afterWaiting, .beforeTimers, .beforeSources, .beforeWaiting, .exit]
            : [.afterWaiting, .beforeWaiting, .exit]

        guard installsRunLoopObserver else { return }

        let install = { [self] in
            guard observer == nil else { return }

            let created = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault,
                activities.rawValue,
                true,               // repeats
                // order 取 CFIndex.min：确保在同一 activity 上比其他 observer 先执行，
                // 这样测到的「本次迭代耗时」才包含别人的 observer 回调。
                CFIndex.min
            ) { [weak self] _, activity in
                self?.handle(activity: activity)
            }

            // 用 commonModes 而不是 defaultMode：否则用户一开始滚动列表，
            // RunLoop 切到 tracking mode，观测就停了——
            // 而滚动恰恰是最需要观测卡顿的场景。上一版用的是 defaultMode。
            CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
            observer = created
        }

        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.sync(execute: install)
        }
    }

    func removeObserver() {
        let existing = lock.withLock { () -> CFRunLoopObserver? in
            let result = observer
            observer = nil
            onIterationEnd = nil
            busySinceUptime = nil
            return result
        }
        guard let existing else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), existing, .commonModes)
    }

    // MARK: - 读取

    /// 供 watchdog 从**后台线程**读取。只加锁读几个字段，不阻塞主线程。
    func snapshot() -> BusySnapshot {
        lock.withLock {
            BusySnapshot(
                busySinceUptime: busySinceUptime,
                mode: currentMode,
                wakeupCount: wakeupCount
            )
        }
    }

    // MARK: - RunLoop 回调

    /// 在主线程上执行。必须极短——这段代码在每次 RunLoop 迭代都会跑，
    /// 它自己变慢就等于给主线程加了固定开销。
    fileprivate func handle(activity: CFRunLoopActivity) {
        let now = clock.uptimeNanos

        switch activity {
        case .afterWaiting:
            // 主线程刚被唤醒，一次工作开始
            let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain())?.rawValue as String?
            lock.withLock {
                busySinceUptime = now
                currentMode = mode
                wakeupCount &+= 1
                afterWaitingUptime = now
                beforeTimersUptime = nil
                beforeSourcesUptime = nil
            }

        case .beforeTimers:
            lock.withLock { beforeTimersUptime = now }

        case .beforeSources:
            lock.withLock { beforeSourcesUptime = now }

        case .beforeWaiting, .exit:
            // 一次工作结束，主线程即将休眠
            let result = lock.withLock { () -> IterationResult? in
                defer {
                    busySinceUptime = nil
                    afterWaitingUptime = nil
                    beforeTimersUptime = nil
                    beforeSourcesUptime = nil
                }
                guard let start = afterWaitingUptime, now > start else { return nil }

                return IterationResult(
                    totalNanos: now - start,
                    timersNanos: Self.interval(from: beforeTimersUptime, to: beforeSourcesUptime),
                    sourcesNanos: Self.interval(from: beforeSourcesUptime, to: now),
                    mode: currentMode
                )
            }

            guard let result else { return }
            let handler = lock.withLock { onIterationEnd }
            handler?(result)

        default:
            break
        }
    }

    private static func interval(from start: UInt64?, to end: UInt64?) -> UInt64 {
        guard let start, let end, end > start else { return 0 }
        return end - start
    }
}


// MARK: - 测试接缝

extension MainThreadStateTracker {
    /// 直接安装迭代结束回调，不挂 RunLoop observer。
    func setIterationHandler(_ handler: @escaping @Sendable (IterationResult) -> Void) {
        lock.withLock { onIterationEnd = handler }
    }

    /// 模拟主线程被唤醒。
    func simulateAfterWaiting() {
        handle(activity: .afterWaiting)
    }

    func simulateBeforeTimers() {
        handle(activity: .beforeTimers)
    }

    func simulateBeforeSources() {
        handle(activity: .beforeSources)
    }

    /// 模拟主线程进入休眠。
    func simulateBeforeWaiting() {
        handle(activity: .beforeWaiting)
    }
}
