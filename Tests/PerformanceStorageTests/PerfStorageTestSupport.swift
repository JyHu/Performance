import Foundation

import PerformanceCore
@testable import PerformanceStorage

// MARK: - 测试用载荷

struct StorageSample: PerfPayload, Equatable {
    static let kind: PerfKind = "sample.metric"
    let index: Int
    let filler: String

    init(index: Int, filler: String = "") {
        self.index = index
        self.filler = filler
    }
}

struct HangSample: PerfPayload, Equatable {
    static let kind: PerfKind = "hang.anr"
    let durationMs: Double
}

struct NetworkSample: PerfRedactablePayload, Equatable {
    static let kind: PerfKind = "network.request"
    let url: String
    let totalMs: Double

    func redacted(using policy: PerfRedactionPolicy) -> NetworkSample {
        NetworkSample(url: policy.redact(urlString: url), totalMs: totalMs)
    }
}

// MARK: - 临时目录

/// 每个用例一个独立的临时目录，退出时清理。
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init(function: String = #function) {
        let name = "perf-store-tests-\(UUID().uuidString)"
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 构造辅助

func makeRecord(
    _ payload: some PerfPayload,
    session: PerfSessionID = PerfSessionID(rawValue: "20260920T103045-AAAAAA"),
    severity: PerfSeverity = .info,
    timestamp: Date = Date(timeIntervalSince1970: 1_758_358_245),
    uptimeNanos: UInt64 = 1_000
) -> PerfAnyRecord {
    PerfAnyRecord(
        timestamp: timestamp,
        uptimeNanos: uptimeNanos,
        sessionID: session,
        severity: severity,
        thread: nil,
        kind: type(of: payload).kind,
        schemaVersion: type(of: payload).schemaVersion,
        payload: payload
    )
}

func makeOptions(
    root: URL,
    maxShardBytes: PerfByteCount = .megabytes(2),
    totalQuota: PerfByteCount = .megabytes(50),
    retention: PerfDuration = .days(7),
    compress: Bool = false
) -> PerfStorageOptions {
    PerfStorageOptions(
        directory: root,
        maxShardBytes: maxShardBytes,
        totalQuota: totalQuota,
        retention: retention,
        compressArchivedShards: compress
    )
}

func fileNames(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}
