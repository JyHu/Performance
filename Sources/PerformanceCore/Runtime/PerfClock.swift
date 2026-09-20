import Foundation

/// 时钟抽象。
///
/// 做成协议而非直接调 `Date()` / `mach_absolute_time()`，是为了让监测器可测试：
/// 上一版所有监测器直接读系统时间，唯一的单元测试只能靠 `Thread.sleep(5)` 来推进时间，
/// 单次跑 10 秒以上，于是 15 个模块里 14 个零覆盖。
public protocol PerfClock: Sendable {
    /// 单调递增的纳秒数，用于计算间隔。不受系统时间调整影响。
    var uptimeNanos: UInt64 { get }

    /// 墙上时钟，用于记录「什么时候发生的」。
    var now: Date { get }
}

extension PerfClock {
    /// 从某个时间点到现在的间隔。
    public func elapsed(since start: UInt64) -> PerfDuration {
        let current = uptimeNanos
        return PerfDuration(nanoseconds: current > start ? current - start : 0)
    }
}

/// 系统时钟。
public struct PerfSystemClock: PerfClock {
    public init() {}

    /// 用 `CLOCK_UPTIME_RAW`：单调、不受 NTP 校正影响，且**不计入设备休眠时间**。
    ///
    /// 不计休眠是刻意的——设备睡了 8 小时不该被算成一次 8 小时的卡顿。
    /// 这与 `mach_absolute_time()` 语义一致，但无需自己处理 timebase 换算。
    public var uptimeNanos: UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    public var now: Date {
        Date()
    }
}

/// 手动推进的时钟，供测试使用。
public final class PerfManualClock: PerfClock, @unchecked Sendable {
    private let lock = PerfLock()
    private var _uptimeNanos: UInt64
    private var _now: Date

    public init(uptimeNanos: UInt64 = 0, now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self._uptimeNanos = uptimeNanos
        self._now = now
    }

    public var uptimeNanos: UInt64 {
        lock.withLock { _uptimeNanos }
    }

    public var now: Date {
        lock.withLock { _now }
    }

    /// 同时推进单调时钟与墙上时钟。
    public func advance(by duration: PerfDuration) {
        lock.withLock {
            _uptimeNanos &+= duration.nanoseconds
            _now = _now.addingTimeInterval(duration.seconds)
        }
    }

    /// 只调整墙上时钟，模拟 NTP 校正 / 用户改时间。
    public func skewWallClock(by interval: TimeInterval) {
        lock.withLock {
            _now = _now.addingTimeInterval(interval)
        }
    }
}
