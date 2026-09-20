import Foundation
import PerformanceCore

/// 磁盘占用的约束。
public struct PerfRetentionPolicy: Sendable {
    public var totalQuota: PerfByteCount
    public var retention: PerfDuration
    public var crashRetention: PerfDuration

    public init(
        totalQuota: PerfByteCount = .megabytes(50),
        retention: PerfDuration = .days(7),
        crashRetention: PerfDuration = .days(30)
    ) {
        self.totalQuota = totalQuota
        self.retention = retention
        self.crashRetention = crashRetention
    }

    public init(storage: PerfStorageOptions) {
        self.init(
            totalQuota: storage.totalQuota,
            retention: storage.retention,
            crashRetention: storage.crashRetention
        )
    }
}

/// 一次清理的结果。
public struct PerfRetentionReport: Sendable, Equatable {
    /// 因超过保留期被删除的 session。
    public var expiredSessions: [PerfSessionID] = []
    /// 因超出配额被删除的 session。
    public var evictedSessions: [PerfSessionID] = []
    /// 被删除的崩溃报告文件数。
    public var removedCrashReports: Int = 0
    public var freedBytes: UInt64 = 0
    /// 清理后仍占用的字节数。
    public var remainingBytes: UInt64 = 0
    /// 配额已尽力清理但仍然超限（当前 session 本身就超了配额）。
    public var isStillOverQuota: Bool = false

    public var totalDeletedSessions: Int {
        expiredSessions.count + evictedSessions.count
    }
}

/// 执行保留策略。
///
/// ## 为什么必须有这一层
///
/// 上一版完全没有配额和清理：上传失败的文件永久留在 Caches 里，
/// 上传器每 30 秒把整个目录重扫一遍全部重传，唯一的终止条件是磁盘写满。
/// 一个性能监控框架把用户的磁盘占满，是比它本想解决的问题严重得多的问题。
///
/// ## 删除顺序
///
/// 1. 超过保留期的 session（按时间）
/// 2. 超过保留期的崩溃报告（单独的、更长的保留期）
/// 3. 若仍超配额，从最旧的 session 开始逐个删除
///
/// **当前 session 永不删除**——正在写入的数据被删掉会让写入器的
/// 文件描述符指向一个已不存在的 inode，后续写入全部静默丢失。
/// 注意本类型**不是** `Sendable`：它持有 `FileManager`，
/// 且只在 `PerfStore` actor 内部按需创建使用，不跨隔离域传递。
public struct PerfRetentionEnforcer {
    private let locator: PerfShardLocator
    private let policy: PerfRetentionPolicy
    private let fileManager: FileManager
    private let log: PerfLog

    public init(
        locator: PerfShardLocator,
        policy: PerfRetentionPolicy,
        fileManager: FileManager = .default,
        log: PerfLog = .disabled
    ) {
        self.locator = locator
        self.policy = policy
        self.fileManager = fileManager
        self.log = log
    }

    @discardableResult
    public func enforce(currentSession: PerfSessionID?, now: Date = Date()) -> PerfRetentionReport {
        var report = PerfRetentionReport()

        var sessions = discoverSessions()
        let expirationDate = now.addingTimeInterval(-policy.retention.seconds)

        // 1. 过期 session
        for session in sessions where session.id != currentSession && session.date < expirationDate {
            report.freedBytes += remove(session)
            report.expiredSessions.append(session.id)
        }
        sessions.removeAll { report.expiredSessions.contains($0.id) }

        // 2. 过期崩溃报告
        let (crashCount, crashBytes) = removeExpiredCrashReports(now: now)
        report.removedCrashReports = crashCount
        report.freedBytes += crashBytes

        // 3. 配额驱逐：从最旧的开始
        var total = sessions.reduce(0) { $0 + $1.byteCount } + crashDirectoryBytes()
        let quota = policy.totalQuota.bytes

        if total > quota {
            for session in sessions.sorted(by: { $0.date < $1.date }) {
                guard total > quota else { break }
                guard session.id != currentSession else { continue }

                let freed = remove(session)
                report.freedBytes += freed
                report.evictedSessions.append(session.id)
                total -= min(total, freed)
            }
        }

        report.remainingBytes = total
        report.isStillOverQuota = total > quota

        if report.isStillOverQuota {
            // 当前 session 自己就撑爆了配额。不能删它，只能告警——
            // 静默超限会让磁盘占用变成一个没人知道的慢性问题。
            log.warning("清理后仍超配额：占用 \(PerfByteCount(bytes: total))，配额 \(policy.totalQuota)")
        }
        if report.totalDeletedSessions > 0 {
            log.info("清理了 \(report.totalDeletedSessions) 个 session，释放 \(PerfByteCount(bytes: report.freedBytes))")
        }

        return report
    }

    /// 当前总占用。
    public func currentUsage() -> PerfByteCount {
        let sessionBytes = discoverSessions().reduce(0) { $0 + $1.byteCount }
        return PerfByteCount(bytes: sessionBytes + crashDirectoryBytes())
    }

    // MARK: - 内部

    struct DiscoveredSession {
        let id: PerfSessionID
        let url: URL
        let date: Date
        let byteCount: UInt64
    }

    func discoverSessions() -> [DiscoveredSession] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: locator.sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        )) ?? []

        return contents.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let id = PerfSessionID(rawValue: url.lastPathComponent)
            return DiscoveredSession(
                id: id,
                url: url,
                date: Self.date(for: id, url: url, fileManager: fileManager),
                byteCount: Self.directorySize(url, fileManager: fileManager)
            )
        }
    }

    /// session 的时间。
    ///
    /// 优先从目录名解析（`20260920T103045-A1B2C3`）；
    /// 名字不符合约定时回退到文件修改时间——目录里可能有别的工具留下的东西，
    /// 不该因为解析不了就当成「永不过期」而一直堆着。
    static func date(for id: PerfSessionID, url: URL, fileManager: FileManager) -> Date {
        if let parsed = parseSessionTimestamp(id.rawValue) {
            return parsed
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.modificationDate] as? Date) ?? .distantPast
    }

    static func parseSessionTimestamp(_ raw: String) -> Date? {
        let stem = raw.split(separator: "-").first.map(String.init) ?? raw
        return sessionFormatter.date(from: stem)
    }

    private static let sessionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()

    static func directorySize(_ url: URL, fileManager: FileManager) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            // 优先用实际分配的块大小：一个 10 字节的文件也会占掉一整个块，
            // 用逻辑大小统计会持续低估，配额形同虚设。
            let size = values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
            total += UInt64(size)
        }
        return total
    }

    private func remove(_ session: DiscoveredSession) -> UInt64 {
        do {
            try fileManager.removeItem(at: session.url)
            return session.byteCount
        } catch {
            log.error("删除 session \(session.id) 失败：\(error.localizedDescription)")
            return 0
        }
    }

    private func crashDirectoryBytes() -> UInt64 {
        Self.directorySize(locator.crashDirectory, fileManager: fileManager)
    }

    private func removeExpiredCrashReports(now: Date) -> (count: Int, bytes: UInt64) {
        let expiration = now.addingTimeInterval(-policy.crashRetention.seconds)
        let contents = (try? fileManager.contentsOfDirectory(
            at: locator.crashDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )) ?? []

        var count = 0
        var bytes: UInt64 = 0
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let modified = values?.contentModificationDate, modified < expiration else { continue }

            let size = UInt64(values?.fileSize ?? 0)
            if (try? fileManager.removeItem(at: url)) != nil {
                count += 1
                bytes += size
            }
        }
        return (count, bytes)
    }
}
