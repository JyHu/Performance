import Foundation
import PerformanceCore

/// 查询过滤条件。
public struct PerfRecordFilter: Sendable {
    /// 精确匹配的类型。nil 表示不限。
    public var kinds: Set<PerfKind>?
    /// 时间范围。nil 表示不限。
    public var range: DateInterval?
    /// 最低严重度。nil 表示不限。
    public var minimumSeverity: PerfSeverity?

    public init(
        kinds: Set<PerfKind>? = nil,
        range: DateInterval? = nil,
        minimumSeverity: PerfSeverity? = nil
    ) {
        self.kinds = kinds
        self.range = range
        self.minimumSeverity = minimumSeverity
    }

    /// 需要读取哪些 kind 大类。nil 表示全部。
    ///
    /// 这是「按大类分文件」这个命名约定的兑现点：
    /// 只查 `hang.anr` 时，`resource-*.jsonl` 整个文件都不必打开。
    public var requiredGroups: Set<String>? {
        guard let kinds else { return nil }
        return Set(kinds.map(\.group))
    }

    func matches(_ record: PerfRawRecord) -> Bool {
        if let kinds, !kinds.contains(record.kind) { return false }
        if let minimumSeverity, record.severity < minimumSeverity { return false }
        if let range, !range.contains(record.timestamp) { return false }
        return true
    }

    public static let all = PerfRecordFilter()
}

/// 单个分片的读取结果。
public struct PerfShardReadResult: Sendable {
    public let records: [PerfRawRecord]
    /// 因解析失败被跳过的行数。
    ///
    /// 显式返回而不是静默吞掉：如果某个分片有大量坏行，
    /// 那是写入侧出了问题，必须能被发现。
    public let skippedLineCount: Int
    /// 文件最后一行是否缺少换行符（进程被杀导致的截断）。
    public let hasTruncatedTail: Bool

    public init(records: [PerfRawRecord], skippedLineCount: Int, hasTruncatedTail: Bool) {
        self.records = records
        self.skippedLineCount = skippedLineCount
        self.hasTruncatedTail = hasTruncatedTail
    }
}

/// JSONL 分片读取器。
///
/// ## 容错策略
///
/// append-only 的每行独立 JSON 带来一个很实际的好处：进程在任意时刻被杀，
/// 损坏范围**最多是最后一行**。读取时遇到无法解析的行直接跳过并计数，
/// 不中断整个文件的读取。
///
/// 这一点对性能框架尤其重要——崩溃前的那几秒数据往往正是最有价值的，
/// 如果整个文件因为末尾半行 JSON 就读不出来，等于白采。
public enum PerfShardReader {
    /// 读取一个分片，收集全部匹配的记录。
    public static func read(
        url: URL,
        filter: PerfRecordFilter = .all,
        chunkSize: Int = 64 * 1024
    ) throws -> PerfShardReadResult {
        var records: [PerfRawRecord] = []
        var skipped = 0
        var truncated = false

        try forEachLine(url: url, chunkSize: chunkSize) { line, isFinalWithoutNewline in
            guard let record = decode(line: line) else {
                skipped += 1
                if isFinalWithoutNewline { truncated = true }
                return true
            }
            if filter.matches(record) {
                records.append(record)
            }
            return true
        }

        return PerfShardReadResult(
            records: records,
            skippedLineCount: skipped,
            hasTruncatedTail: truncated
        )
    }

    /// 流式遍历分片中的记录，不把整个文件读进内存。
    ///
    /// - Parameter body: 返回 `false` 可提前终止遍历。
    public static func forEachRecord(
        url: URL,
        filter: PerfRecordFilter = .all,
        chunkSize: Int = 64 * 1024,
        _ body: (PerfRawRecord) -> Bool
    ) throws {
        try forEachLine(url: url, chunkSize: chunkSize) { line, _ in
            guard let record = decode(line: line), filter.matches(record) else {
                return true
            }
            return body(record)
        }
    }

    // MARK: - 行扫描

    /// 逐行遍历。
    ///
    /// - Parameter body: `(行字节, 该行是否是缺少换行符的末行)`；返回 `false` 终止。
    static func forEachLine(
        url: URL,
        chunkSize: Int,
        _ body: (Data, Bool) -> Bool
    ) throws {
        // 归档分片先整体解压。单片上限是 2MB，一次性载入可接受，
        // 而流式解压 DEFLATE 要维护压缩状态机，复杂度不值得。
        if url.pathExtension == "gz" {
            let compressed = try Data(contentsOf: url)
            guard let plain = PerfGzip.decompress(compressed) else {
                throw PerfStorageError.compressionFailed(path: url.path)
            }
            scanLines(in: plain, body)
            return
        }

        let descriptor = url.path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw PerfStorageError.fileOpenFailed(path: url.path, errno: errno)
        }
        defer { Darwin.close(descriptor) }

        var remainder = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let count = Darwin.read(descriptor, &buffer, chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw PerfStorageError.fileOpenFailed(path: url.path, errno: errno)
            }
            if count == 0 { break }

            remainder.append(contentsOf: buffer[0..<count])

            // 只处理完整的行，剩下的留到下一轮与新数据拼接
            while let newlineIndex = remainder.firstIndex(of: 0x0A) {
                let line = remainder[remainder.startIndex..<newlineIndex]
                remainder = remainder[(newlineIndex + 1)...]
                if !line.isEmpty, !body(Data(line), false) { return }
            }
        }

        // 文件末尾没有换行符：要么是正在写入的分片，要么是进程被杀留下的半行
        if !remainder.isEmpty {
            _ = body(Data(remainder), true)
        }
    }

    private static func scanLines(in data: Data, _ body: (Data, Bool) -> Bool) {
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let slice = data[cursor...]
            guard let newlineIndex = slice.firstIndex(of: 0x0A) else {
                if !slice.isEmpty { _ = body(Data(slice), true) }
                return
            }
            let line = data[cursor..<newlineIndex]
            if !line.isEmpty, !body(Data(line), false) { return }
            cursor = newlineIndex + 1
        }
    }

    private static func decode(line: Data) -> PerfRawRecord? {
        guard let envelope = try? JSONDecoder().decode(PerfRawRecord.Envelope.self, from: line) else {
            return nil
        }
        return PerfRawRecord(lineData: line, envelope: envelope)
    }
}
