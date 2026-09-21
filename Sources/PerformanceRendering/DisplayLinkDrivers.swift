import Foundation
import PerformanceCore
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
import CoreVideo
#endif

/// 创建当前平台可用的帧回调驱动。
///
/// 平台差异全部收敛在这个文件里。上一版把 `CVDisplayLink` 直接写进
/// FPS 监测器，那是它无法在 iOS 上编译的直接原因之一。
public enum PerfDisplayLinkFactory {
    /// - Parameter preferredRefreshRate: 期望的回调频率（Hz）。
    ///   nil 表示跟随屏幕。设低值可以降低监测自身开销，代价是掉帧检测精度下降。
    public static func makeDriver(preferredRefreshRate: Int? = nil) -> any PerfDisplayLinkDriver {
        #if os(iOS)
        return CADisplayLinkDriver(preferredRefreshRate: preferredRefreshRate)
        #elseif os(macOS)
        if #available(macOS 14.0, *), Thread.isMainThread, NSScreen.main != nil {
            return MacCADisplayLinkDriver()
        }
        return CVDisplayLinkDriver()
        #else
        return PerfManualDisplayLink()
        #endif
    }
}

#if os(iOS)

/// iOS 的帧回调驱动。回调发生在**主线程**。
final class CADisplayLinkDriver: NSObject, PerfDisplayLinkDriver, @unchecked Sendable {
    private let lock = PerfLock()
    private var displayLink: CADisplayLink?
    private var handler: (@Sendable (PerfFrameTick) -> Void)?
    private let preferredRefreshRate: Int?

    init(preferredRefreshRate: Int?) {
        self.preferredRefreshRate = preferredRefreshRate
        super.init()
    }

    /// 标称刷新率。
    ///
    /// 在 `start()` 里（主线程上）取好缓存，而不是每次读属性时现查——
    /// `UIScreen.main` 是 main-actor 隔离的，而这个属性会被后台的聚合逻辑读到。
    private var cachedRefreshRate: Double?

    var nominalRefreshRate: Double? {
        lock.withLock { cachedRefreshRate }
    }

    func start(handler: @escaping @Sendable (PerfFrameTick) -> Void) throws {
        lock.withLock { self.handler = handler }

        let install = { [self] in
            // 这个闭包只会在主线程上执行（下面的分支保证了这一点），
            // 但编译器无法推断出来，所以显式断言 main-actor 隔离。
            let refreshRate = MainActor.assumeIsolated {
                Double(UIScreen.main.maximumFramesPerSecond)
            }
            lock.withLock { cachedRefreshRate = refreshRate }

            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(onFrame(_:)))
            if let preferredRefreshRate {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: Float(preferredRefreshRate),
                    maximum: Float(preferredRefreshRate),
                    preferred: Float(preferredRefreshRate)
                )
            }
            // 必须用 .common 模式：默认模式下用户一滚动列表，
            // RunLoop 切到 tracking mode，帧回调就停了——
            // 而滚动恰恰是最需要观测掉帧的场景。
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.sync(execute: install)
        }
    }

    func stop() {
        let teardown = { [self] in
            displayLink?.invalidate()
            displayLink = nil
        }
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.sync(execute: teardown)
        }
        lock.withLock { handler = nil }
    }

    @objc private func onFrame(_ link: CADisplayLink) {
        let handler = lock.withLock { self.handler }
        handler?(
            PerfFrameTick(
                timestamp: link.timestamp,
                targetTimestamp: link.targetTimestamp,
                isMainThread: true
            )
        )
    }
}

#elseif os(macOS)

/// macOS 14+ 的帧回调驱动，基于 `NSScreen.displayLink`。
@available(macOS 14.0, *)
final class MacCADisplayLinkDriver: NSObject, PerfDisplayLinkDriver, @unchecked Sendable {
    private let lock = PerfLock()
    private var displayLink: CADisplayLink?
    private var handler: (@Sendable (PerfFrameTick) -> Void)?
    /// 缓存的主屏幕刷新率。
    ///
    /// 与 iOS 分支同理：`NSScreen.main` 是 main-actor 隔离的，而 `nominalRefreshRate`
    /// 可能被后台的聚合逻辑读取。直接 assumeIsolated 会在非主线程上崩溃，
    /// 所以只在 `start()` 的主线程安装阶段取一次并缓存。
    private var cachedRefreshRate: Double?

    var nominalRefreshRate: Double? {
        lock.withLock { cachedRefreshRate }
    }

    func start(handler: @escaping @Sendable (PerfFrameTick) -> Void) throws {
        lock.withLock { self.handler = handler }

        var thrown: (any Error)?
        let install = { [self] in
            guard displayLink == nil else { return }
            guard let screen = NSScreen.main else {
                thrown = PerfDisplayLinkError.noDisplayAvailable
                return
            }
            lock.withLock { cachedRefreshRate = Double(screen.maximumFramesPerSecond) }
            let link = screen.displayLink(target: self, selector: #selector(onFrame(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.sync(execute: install)
        }
        if let thrown { throw thrown }
    }

    func stop() {
        let teardown = { [self] in
            displayLink?.invalidate()
            displayLink = nil
        }
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.sync(execute: teardown)
        }
        lock.withLock { handler = nil }
    }

    @objc private func onFrame(_ link: CADisplayLink) {
        let handler = lock.withLock { self.handler }
        handler?(
            PerfFrameTick(
                timestamp: link.timestamp,
                targetTimestamp: link.targetTimestamp,
                isMainThread: true
            )
        )
    }
}

/// macOS 12–13 的帧回调驱动。
///
/// 与 iOS 的关键差异：`CVDisplayLink` 的回调跑在**专用高优先级线程**上，
/// 不是主线程。好处是主线程卡死时仍能收到帧回调（因而能观测到卡顿），
/// 坏处是回调里不能直接碰 UI 状态。
///
/// 整个类型标记为 deprecated 以抑制 macOS 15 上 CVDisplayLink 的废弃告警——
/// 在 macOS 14 以下没有替代 API，这个路径必须保留。
@available(macOS, deprecated: 15.0, message: "macOS 14+ 走 MacCADisplayLinkDriver")
final class CVDisplayLinkDriver: PerfDisplayLinkDriver, @unchecked Sendable {
    private let lock = PerfLock()
    private var link: CVDisplayLink?
    private var handler: (@Sendable (PerfFrameTick) -> Void)?

    var nominalRefreshRate: Double? {
        lock.withLock {
            guard let link else { return nil }
            let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
            guard period.timeScale > 0, period.timeValue > 0 else { return nil }
            return Double(period.timeScale) / Double(period.timeValue)
        }
    }

    func start(handler: @escaping @Sendable (PerfFrameTick) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }

        guard link == nil else {
            self.handler = handler
            return
        }
        self.handler = handler

        var created: CVDisplayLink?
        let createResult = CVDisplayLinkCreateWithActiveCGDisplays(&created)
        guard createResult == kCVReturnSuccess, let created else {
            throw PerfDisplayLinkError.creationFailed(code: createResult)
        }

        let callbackResult = CVDisplayLinkSetOutputCallback(
            created,
            { _, inNow, inOutputTime, _, _, userInfo in
                guard let userInfo else { return kCVReturnSuccess }
                let driver = Unmanaged<CVDisplayLinkDriver>.fromOpaque(userInfo).takeUnretainedValue()
                driver.emit(now: inNow.pointee, outputTime: inOutputTime.pointee)
                return kCVReturnSuccess
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard callbackResult == kCVReturnSuccess else {
            throw PerfDisplayLinkError.creationFailed(code: callbackResult)
        }

        let startResult = CVDisplayLinkStart(created)
        guard startResult == kCVReturnSuccess else {
            throw PerfDisplayLinkError.creationFailed(code: startResult)
        }
        link = created
    }

    func stop() {
        lock.lock()
        let existing = link
        link = nil
        handler = nil
        lock.unlock()

        guard let existing else { return }
        CVDisplayLinkStop(existing)
    }

    private func emit(now: CVTimeStamp, outputTime: CVTimeStamp) {
        let handler = lock.withLock { self.handler }
        guard let handler else { return }

        handler(
            PerfFrameTick(
                timestamp: Self.seconds(from: now),
                targetTimestamp: Self.seconds(from: outputTime),
                isMainThread: false
            )
        )
    }

    private static func seconds(from timestamp: CVTimeStamp) -> CFTimeInterval {
        guard timestamp.videoTimeScale > 0 else { return 0 }
        return CFTimeInterval(timestamp.videoTime) / CFTimeInterval(timestamp.videoTimeScale)
    }
}

#endif
