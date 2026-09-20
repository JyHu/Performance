import Foundation
import Testing

import PerformanceCore
@testable import PerformanceStorage

@Suite("保留策略")
struct PerfRetentionTests {
    private let fileManager = FileManager.default

    /// 用可读的 ISO 串构造时间。
    ///
    /// 不直接写 epoch 数字：session 目录名是 `yyyyMMdd'T'HHmmss` 格式，
    /// 而 epoch 常量与之完全对不上眼，写错了要靠跑测试才发现。
    private func date(_ iso8601: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso8601)!
    }

    /// 造一个占指定字节数的 session 目录。
    @discardableResult
    private func makeSession(
        root: URL,
        id: String,
        bytes: Int,
        modifiedAt: Date? = nil
    ) throws -> PerfSessionID {
        let locator = PerfShardLocator(root: root)
        let session = PerfSessionID(rawValue: id)
        let directory = locator.directory(for: session)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data(repeating: 0x61, count: bytes)
            .write(to: directory.appendingPathComponent("hang-000.jsonl"))

        if let modifiedAt {
            try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: directory.path)
        }
        return session
    }

    private func enforcer(root: URL, policy: PerfRetentionPolicy) -> PerfRetentionEnforcer {
        PerfRetentionEnforcer(locator: PerfShardLocator(root: root), policy: policy)
    }

    private func existingSessionNames(root: URL) -> [String] {
        fileNames(in: PerfShardLocator(root: root).sessionsDirectory)
    }

    @Test("超过保留期的 session 被删除")
    func removesExpiredSessions() throws {
        let temp = TemporaryDirectory()
        try makeSession(root: temp.url, id: "20260901T120000-OLD001", bytes: 100)   // 19 天前
        try makeSession(root: temp.url, id: "20260919T120000-NEW001", bytes: 100)   // 1 天前

        let report = enforcer(
            root: temp.url,
            policy: PerfRetentionPolicy(retention: .days(7))
        ).enforce(currentSession: nil, now: date("2026-09-20T12:00:00Z"))

        #expect(report.expiredSessions.map(\.rawValue) == ["20260901T120000-OLD001"])
        #expect(existingSessionNames(root: temp.url) == ["20260919T120000-NEW001"])
    }

    @Test("当前 session 永不删除，即使已超保留期")
    func neverRemovesCurrentSession() throws {
        let temp = TemporaryDirectory()
        let current = try makeSession(root: temp.url, id: "20260101T120000-CUR001", bytes: 100)

        let report = enforcer(
            root: temp.url,
            policy: PerfRetentionPolicy(retention: .days(1))
        ).enforce(currentSession: current, now: date("2026-09-20T12:00:00Z"))

        #expect(report.expiredSessions.isEmpty)
        #expect(existingSessionNames(root: temp.url) == ["20260101T120000-CUR001"])
    }

    @Test("超出配额时从最旧的 session 开始驱逐")
    func evictsOldestWhenOverQuota() throws {
        let temp = TemporaryDirectory()

        try makeSession(root: temp.url, id: "20260918T100000-A00001", bytes: 40_000)
        try makeSession(root: temp.url, id: "20260919T100000-B00001", bytes: 40_000)
        let current = try makeSession(root: temp.url, id: "20260920T100000-C00001", bytes: 40_000)

        let report = enforcer(
            root: temp.url,
            policy: PerfRetentionPolicy(totalQuota: .kilobytes(100), retention: .days(365))
        ).enforce(currentSession: current, now: date("2026-09-20T12:00:00Z"))

        // 最旧的先走
        #expect(report.evictedSessions.first?.rawValue == "20260918T100000-A00001")
        #expect(!existingSessionNames(root: temp.url).contains("20260918T100000-A00001"))
        // 当前 session 留着
        #expect(existingSessionNames(root: temp.url).contains("20260920T100000-C00001"))
    }

    @Test("当前 session 自己就超配额时给出明确标记，而不是静默超限")
    func flagsWhenStillOverQuota() throws {
        let temp = TemporaryDirectory()
        let current = try makeSession(root: temp.url, id: "20260920T100000-BIG001", bytes: 200_000)

        let report = enforcer(
            root: temp.url,
            policy: PerfRetentionPolicy(totalQuota: .kilobytes(50), retention: .days(365))
        ).enforce(currentSession: current, now: date("2026-09-20T12:00:00Z"))

        #expect(report.isStillOverQuota)
        #expect(existingSessionNames(root: temp.url) == ["20260920T100000-BIG001"])
    }

    @Test("配额充足时不删任何东西")
    func keepsEverythingUnderQuota() throws {
        let temp = TemporaryDirectory()
        try makeSession(root: temp.url, id: "20260919T100000-A00001", bytes: 1_000)
        try makeSession(root: temp.url, id: "20260920T100000-B00001", bytes: 1_000)

        let report = enforcer(
            root: temp.url,
            policy: PerfRetentionPolicy(totalQuota: .megabytes(50), retention: .days(365))
        ).enforce(currentSession: nil, now: date("2026-09-20T12:00:00Z"))

        #expect(report.totalDeletedSessions == 0)
        #expect(!report.isStillOverQuota)
        #expect(existingSessionNames(root: temp.url).count == 2)
    }

    @Test("目录名不符合约定时回退到文件修改时间，不会被当成永不过期")
    func fallsBackToModificationDate() throws {
        let temp = TemporaryDirectory()
        let ancient = Date(timeIntervalSince1970: 1_000_000_000)
        try makeSession(root: temp.url, id: "not-a-timestamp", bytes: 100, modifiedAt: ancient)

        let report = enforcer(
            root: temp.url,
            policy: PerfRetentionPolicy(retention: .days(7))
        ).enforce(currentSession: nil, now: date("2026-09-20T12:00:00Z"))

        #expect(report.expiredSessions.map(\.rawValue) == ["not-a-timestamp"])
    }

    @Test("崩溃报告按更长的独立保留期清理")
    func usesSeparateCrashRetention() throws {
        let temp = TemporaryDirectory()
        let locator = PerfShardLocator(root: temp.url)
        try fileManager.createDirectory(at: locator.crashDirectory, withIntermediateDirectories: true)

        let old = locator.crashDirectory.appendingPathComponent("old.raw")
        let recent = locator.crashDirectory.appendingPathComponent("recent.raw")
        try Data(repeating: 0, count: 10).write(to: old)
        try Data(repeating: 0, count: 10).write(to: recent)

        let now = date("2026-09-20T12:00:00Z")
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-40 * 86_400)],
            ofItemAtPath: old.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10 * 86_400)],
            ofItemAtPath: recent.path
        )

        let report = enforcer(
            root: temp.url,
            // 常规数据 7 天就过期，但崩溃报告留 30 天
            policy: PerfRetentionPolicy(retention: .days(7), crashRetention: .days(30))
        ).enforce(currentSession: nil, now: now)

        #expect(report.removedCrashReports == 1)
        #expect(fileNames(in: locator.crashDirectory) == ["recent.raw"])
    }

    @Test("session 时间戳解析")
    func parsesSessionTimestamp() throws {
        let date = try #require(
            PerfRetentionEnforcer.parseSessionTimestamp("20260920T103045-A1B2C3")
        )
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 20
        components.hour = 10
        components.minute = 30
        components.second = 45

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(date == calendar.date(from: components))
    }
}
