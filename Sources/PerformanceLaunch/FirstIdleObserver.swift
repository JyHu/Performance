import CoreFoundation
import Foundation
import PerformanceCore

/// 观测主 RunLoop 的**首次**空闲时刻，作为首帧渲染完成的代理指标。
///
/// ## 为什么是代理指标而不是真实首帧
///
/// 「首帧渲染完成」这件事在 iOS 上没有公开的通知可以监听。
/// 常见的替代是 `CATransaction` 完成回调，但框架不一定能赶在
/// 第一个 transaction 提交之前就位。
///
/// 「主 RunLoop 第一次进入休眠」意味着本轮所有工作（含布局、绘制提交）
/// 都已做完，因此它**略晚于**真实首帧，但稳定可得，
/// 而且不依赖业务方做任何接入。
///
/// 业务方若在真正的首屏出现处调用 `PerfLaunchTimeline.markFirstFrame()`，
/// 监测器会优先采用那个更准确的值，并在数据里标明来源。
final class FirstIdleObserver: @unchecked Sendable {
    private let lock = PerfLock()
    private var observer: CFRunLoopObserver?
    private var handler: (@Sendable (UInt64) -> Void)?
    private let clock: any PerfClock

    init(clock: any PerfClock) {
        self.clock = clock
    }

    deinit {
        remove()
    }

    /// 安装观测。回调只会触发一次。
    func install(onFirstIdle: @escaping @Sendable (UInt64) -> Void) {
        lock.withLock { handler = onFirstIdle }

        let install: @Sendable () -> Void = { [self] in
            guard lock.withLock({ observer == nil }) else { return }

            let created = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault,
                CFRunLoopActivity.beforeWaiting.rawValue,
                false,          // 非重复：首次空闲就是我们要的时刻
                // order 取最大值，排在所有其他 observer 之后，
                // 确保本轮 RunLoop 的工作确实全部做完了
                CFIndex.max
            ) { [weak self] _, _ in
                self?.fire()
            }

            lock.withLock { observer = created }
            CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        }

        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.async(execute: install)
        }
    }

    func remove() {
        let existing = lock.withLock { () -> CFRunLoopObserver? in
            let result = observer
            observer = nil
            handler = nil
            return result
        }
        guard let existing else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), existing, .commonModes)
    }

    private func fire() {
        let uptime = clock.uptimeNanos
        // 取出并清空 handler，保证只回调一次——
        // 非重复的 observer 理论上只触发一次，但 RunLoop 嵌套时不保证
        let handler = lock.withLock { () -> (@Sendable (UInt64) -> Void)? in
            let result = self.handler
            self.handler = nil
            return result
        }
        handler?(uptime)
        remove()
    }
}
