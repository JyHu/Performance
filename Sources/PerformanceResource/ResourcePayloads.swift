import Foundation
import PerformanceCore

/// CPU 采样。
public struct PerfCPUSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "resource.cpu"

    /// 进程在本次采样窗口内的平均 CPU 占用率。多核满载时可超过 100。
    public let processPercent: Double
    /// 采样窗口时长（毫秒）。
    ///
    /// 必须带上：百分比脱离时间窗口就无法跨采样周期比较，
    /// 也无法判断一个 300% 是「持续三核满载」还是「一次 10ms 的尖峰」。
    public let windowMs: Double
    /// 窗口内占用最高的若干线程。
    public let topThreads: [PerfThreadUsage]
    /// 当前线程总数。
    public let threadCount: Int

    public init(processPercent: Double, windowMs: Double, topThreads: [PerfThreadUsage], threadCount: Int) {
        self.processPercent = processPercent
        self.windowMs = windowMs
        self.topThreads = topThreads
        self.threadCount = threadCount
    }
}

/// 单个线程的占用情况。
public struct PerfThreadUsage: Codable, Sendable, Equatable {
    public let name: String?
    public let isMain: Bool
    public let percent: Double

    public init(name: String?, isMain: Bool, percent: Double) {
        self.name = name
        self.isMain = isMain
        self.percent = percent
    }
}

/// 内存采样。
public struct PerfMemorySample: PerfPayload, Equatable {
    public static let kind: PerfKind = "resource.memory"

    /// 物理内存足迹（MB）。这是 iOS jetsam 判定用的指标。
    public let footprintMB: Double
    /// 常驻内存（MB），含与系统共享的页。
    public let residentMB: Double
    /// 相对本次 session 首次采样的增长量（MB）。
    ///
    /// 绝对值高不一定是问题——图片缓存本来就占内存；
    /// **持续增长**才是泄漏的信号。所以增长量要单独成一个维度。
    public let growthSinceBaselineMB: Double
    /// 进程可用内存上限的剩余量（MB）。取不到时为 nil。
    public let availableToProcessMB: Double?
    /// 系统可用物理内存（MB）。
    public let systemAvailableMB: Double?

    public init(
        footprintMB: Double,
        residentMB: Double,
        growthSinceBaselineMB: Double,
        availableToProcessMB: Double?,
        systemAvailableMB: Double?
    ) {
        self.footprintMB = footprintMB
        self.residentMB = residentMB
        self.growthSinceBaselineMB = growthSinceBaselineMB
        self.availableToProcessMB = availableToProcessMB
        self.systemAvailableMB = systemAvailableMB
    }
}

/// 内核活动采样。
public struct PerfKernelActivitySample: PerfPayload, Equatable {
    public static let kind: PerfKind = "resource.kernel"

    /// 窗口内新增的缺页换入次数。激增往往先于内存告警出现。
    public let pageinsDelta: UInt64
    /// 窗口内新增的上下文切换次数。
    ///
    /// 异常增长意味着线程在互相抢占——线程池失控或锁竞争的典型信号，
    /// 而这时 CPU 占用率可能看起来完全正常。
    public let contextSwitchesDelta: UInt64
    public let windowMs: Double

    public init(pageinsDelta: UInt64, contextSwitchesDelta: UInt64, windowMs: Double) {
        self.pageinsDelta = pageinsDelta
        self.contextSwitchesDelta = contextSwitchesDelta
        self.windowMs = windowMs
    }
}
