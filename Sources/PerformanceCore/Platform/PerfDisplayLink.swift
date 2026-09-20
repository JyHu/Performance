import Foundation

/// 一次屏幕刷新回调。
public struct PerfFrameTick: Sendable {
    /// 本帧的时间戳（秒，单调）。
    public let timestamp: CFTimeInterval
    /// 系统预期的下一帧时间戳。
    ///
    /// `targetTimestamp - timestamp` 给出**本次**的目标帧间隔，
    /// 这比假定固定 60Hz 可靠得多——ProMotion 设备会在 10~120Hz 之间动态变化，
    /// 外接显示器、低电量模式、后台状态都会改变刷新率。
    /// 上一版把目标帧率当常量处理，在 120Hz 设备上会把正常帧误判成掉帧。
    public let targetTimestamp: CFTimeInterval
    /// 回调是否发生在主线程。
    ///
    /// iOS 的 `CADisplayLink` 在主线程回调，macOS 的 `CVDisplayLink` 在专用线程回调。
    /// 这个差异会影响「能否顺带观测主线程状态」，因此显式暴露出来。
    public let isMainThread: Bool

    public init(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval, isMainThread: Bool) {
        self.timestamp = timestamp
        self.targetTimestamp = targetTimestamp
        self.isMainThread = isMainThread
    }

    /// 本次的目标帧间隔（秒）。异常值回退到 60Hz。
    public var targetFrameInterval: CFTimeInterval {
        let interval = targetTimestamp - timestamp
        return interval > 0 && interval < 1 ? interval : 1.0 / 60.0
    }
}

/// 屏幕刷新回调源。
///
/// 协议定义在 Core，具体驱动（iOS 的 `CADisplayLink`、macOS 的 `CVDisplayLink`）
/// 实现在 `PerfRendering`——那里才是需要真正接屏幕的地方，
/// 也避免让不做渲染监测的使用者链接 QuartzCore / CoreVideo。
public protocol PerfDisplayLinkDriver: AnyObject, Sendable {
    /// 标称刷新率（Hz）。取不到时返回 nil，调用方应改用 `PerfFrameTick.targetFrameInterval`。
    var nominalRefreshRate: Double? { get }

    /// 开始接收帧回调。重复调用应当是幂等的。
    func start(handler: @escaping @Sendable (PerfFrameTick) -> Void) throws

    /// 停止并释放底层资源。重复调用应当是幂等的。
    func stop()
}

public enum PerfDisplayLinkError: Error, Sendable {
    /// 当前环境没有可用的显示器（无头环境、后台进程）。
    case noDisplayAvailable
    /// 底层 API 返回错误。
    case creationFailed(code: Int32)
}

/// 手动驱动的帧回调源，供测试使用。
///
/// 让「模拟一段 120 帧、其中第 40 帧卡了 200ms 的序列」变成一串同步调用。
public final class PerfManualDisplayLink: PerfDisplayLinkDriver, @unchecked Sendable {
    private let lock = PerfLock()
    private var handler: (@Sendable (PerfFrameTick) -> Void)?
    private var currentTimestamp: CFTimeInterval

    public let nominalRefreshRate: Double?

    public init(startTimestamp: CFTimeInterval = 0, nominalRefreshRate: Double? = 60) {
        self.currentTimestamp = startTimestamp
        self.nominalRefreshRate = nominalRefreshRate
    }

    public func start(handler: @escaping @Sendable (PerfFrameTick) -> Void) throws {
        lock.withLock { self.handler = handler }
    }

    public func stop() {
        lock.withLock { self.handler = nil }
    }

    /// 推进一帧。
    ///
    /// - Parameter interval: 本帧实际耗时。传入大于目标间隔的值即可模拟掉帧。
    public func advance(by interval: CFTimeInterval, targetInterval: CFTimeInterval = 1.0 / 60.0) {
        let (handler, timestamp) = lock.withLock { () -> ((@Sendable (PerfFrameTick) -> Void)?, CFTimeInterval) in
            currentTimestamp += interval
            return (self.handler, currentTimestamp)
        }
        handler?(
            PerfFrameTick(
                timestamp: timestamp,
                targetTimestamp: timestamp + targetInterval,
                isMainThread: Thread.isMainThread
            )
        )
    }
}
