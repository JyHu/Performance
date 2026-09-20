import Darwin
import Foundation
import PerformanceCore

/// 进程累计磁盘 I/O。
///
/// 同样上报累计值，由调用方做差分——理由与 CPU 时间相同。
public struct PerfDiskIO: Sendable, Hashable {
    public let bytesRead: UInt64
    public let bytesWritten: UInt64

    public init(bytesRead: UInt64, bytesWritten: UInt64) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }

    /// 相对上一次采样的吞吐（字节/秒）。
    public func throughput(since previous: PerfDiskIO, elapsed: PerfDuration) -> (read: Double, written: Double) {
        guard elapsed.seconds > 0 else { return (0, 0) }
        let readDelta = bytesRead > previous.bytesRead ? bytesRead - previous.bytesRead : 0
        let writeDelta = bytesWritten > previous.bytesWritten ? bytesWritten - previous.bytesWritten : 0
        return (Double(readDelta) / elapsed.seconds, Double(writeDelta) / elapsed.seconds)
    }
}

/// 卷容量。
public struct PerfVolumeCapacity: Sendable, Hashable {
    public let totalBytes: UInt64
    /// 「重要」用途的可用容量。
    ///
    /// 这是系统给出的、考虑了可清理缓存后的真实可用量，
    /// 比 `volumeAvailableCapacity` 更贴近「还能写多少」。
    public let availableForImportantUsageBytes: UInt64?
    /// 不考虑可清理空间的可用容量。
    public let availableBytes: UInt64?
}

public enum PerfDiskMetrics {
    /// 进程累计磁盘 I/O。
    ///
    /// 这是**真正的** I/O 计量，来自内核而非应用层埋点。
    /// 上一版的「I/O 监控」只是在自己封装的 `readData`/`writeData` 里掐表——
    /// 业务方任何一处直接用 `Data(contentsOf:)`、`FileHandle`、SQLite，
    /// 都完全不在统计范围内，于是磁盘再忙，数据看起来也是零。
    ///
    /// - Returns: **iOS 上恒为 nil**。该平台没有公开 API 能拿到进程磁盘 I/O，
    ///   唯一的来源是 `proc_pid_rusage`，而它在 iOS SDK 里没有声明，
    ///   用它等于私有 API。iOS 请改用 `PerfMetricKit` 的磁盘指标。
    public static func processIO() -> PerfDiskIO? {
        guard let usage = PerfCPUMetrics.resourceUsage(), usage.has_disk_io else { return nil }
        return PerfDiskIO(
            bytesRead: usage.disk_bytes_read,
            bytesWritten: usage.disk_bytes_written
        )
    }

    /// 指定卷的容量。默认查 app 容器所在卷。
    public static func volumeCapacity(for url: URL? = nil) -> PerfVolumeCapacity? {
        let target = url ?? URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]

        guard let values = try? target.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity
        else { return nil }

        return PerfVolumeCapacity(
            totalBytes: UInt64(max(0, total)),
            availableForImportantUsageBytes: values.volumeAvailableCapacityForImportantUsage
                .map { UInt64(max(0, $0)) },
            availableBytes: values.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
        )
    }
}
