import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// app 生命周期事件。
public enum PerfAppLifecycleEvent: String, Sendable, Codable, CaseIterable {
    case didFinishLaunching
    case didBecomeActive
    case willResignActive
    /// iOS 专有。macOS 上不会触发。
    case didEnterBackground
    /// iOS 专有。macOS 上不会触发。
    case willEnterForeground
    case willTerminate
    /// iOS 专有。内存告警是排查 OOM 的关键信号。
    case didReceiveMemoryWarning
}

public struct PerfLifecycleToken: Hashable, Sendable {
    let id: UInt64
}

/// 生命周期事件源。
///
/// 启动耗时、热启动、前后台切换期间的采样策略调整都依赖它。
/// 抽象成协议让测试可以直接「制造」一次进入后台，而不必真的操作 app 状态。
public protocol PerfAppLifecycleProviding: Sendable {
    @discardableResult
    func observe(_ handler: @escaping @Sendable (PerfAppLifecycleEvent, Date) -> Void) -> PerfLifecycleToken

    func removeObserver(_ token: PerfLifecycleToken)
}

/// 系统生命周期通知的统一封装。
///
/// iOS 与 macOS 的通知名完全不同（`UIApplication.*` vs `NSApplication.*`），
/// 且 macOS 没有前后台切换和内存告警的对应概念。
/// 把差异收敛在这一个文件里，采集器只面对统一的 `PerfAppLifecycleEvent`。
///
/// 上一版把 `NSApplication.didFinishLaunchingNotification` 直接写在
/// 启动监测器里，是它无法在 iOS 上编译的原因之一。
public final class PerfAppLifecycle: PerfAppLifecycleProviding, @unchecked Sendable {
    private let lock = PerfLock()
    private var handlers: [UInt64: @Sendable (PerfAppLifecycleEvent, Date) -> Void] = [:]
    private var nextTokenID: UInt64 = 1
    private var observations: [NSObjectProtocol] = []

    private let notificationCenter: NotificationCenter
    private let clock: any PerfClock

    public init(
        notificationCenter: NotificationCenter = .default,
        clock: any PerfClock = PerfSystemClock()
    ) {
        self.notificationCenter = notificationCenter
        self.clock = clock
        subscribeToSystemNotifications()
    }

    deinit {
        for observation in observations {
            notificationCenter.removeObserver(observation)
        }
    }

    @discardableResult
    public func observe(
        _ handler: @escaping @Sendable (PerfAppLifecycleEvent, Date) -> Void
    ) -> PerfLifecycleToken {
        lock.withLock {
            let id = nextTokenID
            nextTokenID &+= 1
            handlers[id] = handler
            return PerfLifecycleToken(id: id)
        }
    }

    public func removeObserver(_ token: PerfLifecycleToken) {
        lock.withLock { _ = handlers.removeValue(forKey: token.id) }
    }

    // MARK: - 系统通知映射

    private func subscribeToSystemNotifications() {
        for (name, event) in Self.notificationMap {
            let observation = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil                      // 在发帖线程同步回调，不改变时序
            ) { [weak self] _ in
                self?.dispatch(event)
            }
            observations.append(observation)
        }
    }

    /// 平台差异的**唯一**落点。
    private static var notificationMap: [(Notification.Name, PerfAppLifecycleEvent)] {
        #if canImport(UIKit) && !os(watchOS)
        return [
            (UIApplication.didFinishLaunchingNotification, .didFinishLaunching),
            (UIApplication.didBecomeActiveNotification, .didBecomeActive),
            (UIApplication.willResignActiveNotification, .willResignActive),
            (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.willEnterForegroundNotification, .willEnterForeground),
            (UIApplication.willTerminateNotification, .willTerminate),
            (UIApplication.didReceiveMemoryWarningNotification, .didReceiveMemoryWarning),
        ]
        #elseif canImport(AppKit)
        return [
            (NSApplication.didFinishLaunchingNotification, .didFinishLaunching),
            (NSApplication.didBecomeActiveNotification, .didBecomeActive),
            (NSApplication.willResignActiveNotification, .willResignActive),
            (NSApplication.willTerminateNotification, .willTerminate),
        ]
        #else
        return []
        #endif
    }

    private func dispatch(_ event: PerfAppLifecycleEvent) {
        let date = clock.now
        let snapshot = lock.withLock { Array(handlers.values) }
        for handler in snapshot {
            handler(event, date)
        }
    }
}

/// 手动触发的生命周期源，供测试使用。
public final class PerfManualAppLifecycle: PerfAppLifecycleProviding, @unchecked Sendable {
    private let lock = PerfLock()
    private var handlers: [UInt64: @Sendable (PerfAppLifecycleEvent, Date) -> Void] = [:]
    private var nextTokenID: UInt64 = 1

    public init() {}

    @discardableResult
    public func observe(
        _ handler: @escaping @Sendable (PerfAppLifecycleEvent, Date) -> Void
    ) -> PerfLifecycleToken {
        lock.withLock {
            let id = nextTokenID
            nextTokenID &+= 1
            handlers[id] = handler
            return PerfLifecycleToken(id: id)
        }
    }

    public func removeObserver(_ token: PerfLifecycleToken) {
        lock.withLock { _ = handlers.removeValue(forKey: token.id) }
    }

    /// 制造一次生命周期事件。
    public func send(_ event: PerfAppLifecycleEvent, at date: Date = Date()) {
        let snapshot = lock.withLock { Array(handlers.values) }
        for handler in snapshot {
            handler(event, date)
        }
    }
}
