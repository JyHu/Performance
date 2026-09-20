import Foundation
import Testing

import PerformanceCore
@testable import PerformanceStorage

// MARK: - 分片命名

@Suite("分片命名")
struct PerfShardDescriptorTests {
    @Test("解析普通分片文件名")
    func parsesPlainShard() throws {
        let descriptor = try #require(
            PerfShardDescriptor.parse(url: URL(fileURLWithPath: "/tmp/s/hang-007.jsonl"))
        )
        #expect(descriptor.group == "hang")
        #expect(descriptor.index == 7)
        #expect(!descriptor.isArchived)
    }

    @Test("解析归档分片文件名")
    func parsesArchivedShard() throws {
        let descriptor = try #require(
            PerfShardDescriptor.parse(url: URL(fileURLWithPath: "/tmp/s/rendering-012.jsonl.gz"))
        )
        #expect(descriptor.group == "rendering")
        #expect(descriptor.index == 12)
        #expect(descriptor.isArchived)
    }

    @Test("不认识的文件被跳过而不是报错")
    func ignoresUnknownFiles() {
        #expect(PerfShardDescriptor.parse(url: URL(fileURLWithPath: "/tmp/s/manifest.json")) == nil)
        #expect(PerfShardDescriptor.parse(url: URL(fileURLWithPath: "/tmp/s/README.md")) == nil)
        #expect(PerfShardDescriptor.parse(url: URL(fileURLWithPath: "/tmp/s/hang.jsonl")) == nil)
        #expect(PerfShardDescriptor.parse(url: URL(fileURLWithPath: "/tmp/s/hang-abc.jsonl")) == nil)
    }

    @Test("序号补零到三位，保证字典序与数值序一致")
    func padsIndexForLexicographicOrder() {
        let locator = PerfShardLocator(root: URL(fileURLWithPath: "/tmp"))
        let session = PerfSessionID(rawValue: "s")

        let second = locator.shardURL(session: session, group: "hang", index: 2).lastPathComponent
        let tenth = locator.shardURL(session: session, group: "hang", index: 10).lastPathComponent

        #expect(second == "hang-002.jsonl")
        #expect(tenth == "hang-010.jsonl")
        // 不补零的话 "hang-10" < "hang-2"，读取顺序会乱
        #expect(second < tenth)
    }
}

// MARK: - 写入与滚动

@Suite("分片写入与滚动")
struct PerfShardWriterTests {
    private func makeWriter(
        root: URL,
        group: String = "hang",
        maxShardBytes: PerfByteCount
    ) throws -> PerfShardWriter {
        try PerfShardWriter(
            locator: PerfShardLocator(root: root),
            session: PerfSessionID(rawValue: "20260920T103045-AAAAAA"),
            group: group,
            maxShardBytes: maxShardBytes
        )
    }

    private func line(_ size: Int) -> Data {
        Data(repeating: 0x61, count: size)   // 'a' * size
    }

    @Test("每条记录一行，行尾补换行符")
    func writesOneLinePerRecord() throws {
        let temp = TemporaryDirectory()
        let writer = try makeWriter(root: temp.url, maxShardBytes: .megabytes(1))

        try writer.append(lines: [line(10), line(20), line(30)])
        writer.close()

        let content = try Data(contentsOf: writer.currentShardURL)
        #expect(content.count == 10 + 20 + 30 + 3)
        #expect(content.filter { $0 == 0x0A }.count == 3)
        #expect(content.last == 0x0A)
    }

    @Test("超过分片上限时滚动到下一个分片")
    func rollsWhenExceedingLimit() throws {
        let temp = TemporaryDirectory()
        // 上限 100 字节，每行 30+1 字节 → 第 4 行触发滚动
        let writer = try makeWriter(root: temp.url, maxShardBytes: .bytes(100))

        try writer.append(lines: Array(repeating: line(30), count: 5))
        writer.close()

        let sessionDir = PerfShardLocator(root: temp.url)
            .directory(for: PerfSessionID(rawValue: "20260920T103045-AAAAAA"))
        let names = fileNames(in: sessionDir)

        #expect(names == ["hang-000.jsonl", "hang-001.jsonl"])

        // 没有任何一个分片超过上限
        for name in names {
            let size = try Data(contentsOf: sessionDir.appendingPathComponent(name)).count
            #expect(size <= 100)
        }

        // 五行一条不少
        let totalNewlines = try names.reduce(0) { partial, name in
            let data = try Data(contentsOf: sessionDir.appendingPathComponent(name))
            return partial + data.filter { $0 == 0x0A }.count
        }
        #expect(totalNewlines == 5)
    }

    @Test("单条记录超过分片上限时独占一个分片，不会死循环")
    func handlesOversizedRecord() throws {
        let temp = TemporaryDirectory()
        let writer = try makeWriter(root: temp.url, maxShardBytes: .bytes(50))

        try writer.append(lines: [line(10), line(500), line(10)])
        writer.close()

        let sessionDir = PerfShardLocator(root: temp.url)
            .directory(for: PerfSessionID(rawValue: "20260920T103045-AAAAAA"))
        let names = fileNames(in: sessionDir)

        // 三条记录全部写出，没有丢失
        let totalNewlines = try names.reduce(0) { partial, name in
            let data = try Data(contentsOf: sessionDir.appendingPathComponent(name))
            return partial + data.filter { $0 == 0x0A }.count
        }
        #expect(totalNewlines == 3)

        // 超大记录独占一片
        let hasOversizedShard = try names.contains { name in
            try Data(contentsOf: sessionDir.appendingPathComponent(name)).count > 50
        }
        #expect(hasOversizedShard)
    }

    @Test("重建写入器时接着已有分片写，不覆盖")
    func resumesFromExistingShards() throws {
        let temp = TemporaryDirectory()

        let first = try makeWriter(root: temp.url, maxShardBytes: .bytes(60))
        try first.append(lines: Array(repeating: line(25), count: 3))   // 滚动到 001
        first.close()

        let second = try makeWriter(root: temp.url, maxShardBytes: .bytes(60))
        try second.append(lines: [line(25)])
        second.close()

        let sessionDir = PerfShardLocator(root: temp.url)
            .directory(for: PerfSessionID(rawValue: "20260920T103045-AAAAAA"))

        let totalNewlines = try fileNames(in: sessionDir).reduce(0) { partial, name in
            let data = try Data(contentsOf: sessionDir.appendingPathComponent(name))
            return partial + data.filter { $0 == 0x0A }.count
        }
        #expect(totalNewlines == 4)   // 3 + 1，没有任何一条被覆盖
    }

    @Test("不同大类写到不同文件")
    func separatesGroups() throws {
        let temp = TemporaryDirectory()
        let hang = try makeWriter(root: temp.url, group: "hang", maxShardBytes: .megabytes(1))
        let resource = try makeWriter(root: temp.url, group: "resource", maxShardBytes: .megabytes(1))

        try hang.append(lines: [line(10)])
        try resource.append(lines: [line(10)])
        hang.close()
        resource.close()

        let sessionDir = PerfShardLocator(root: temp.url)
            .directory(for: PerfSessionID(rawValue: "20260920T103045-AAAAAA"))
        #expect(fileNames(in: sessionDir) == ["hang-000.jsonl", "resource-000.jsonl"])
    }
}

// MARK: - 读取容错

@Suite("读取容错")
struct PerfShardReaderTests {
    private func writeLines(_ content: String, to url: URL) throws {
        try content.data(using: .utf8)!.write(to: url)
    }

    private func encodedLine(_ payload: some PerfPayload, severity: PerfSeverity = .info) throws -> String {
        let data = try JSONEncoder().encode(makeRecord(payload, severity: severity))
        return String(decoding: data, as: UTF8.self)
    }

    @Test("正常文件全部读出")
    func readsAllRecords() throws {
        let temp = TemporaryDirectory()
        let url = temp.url.appendingPathComponent("sample-000.jsonl")

        let lines = try (0..<5).map { try encodedLine(StorageSample(index: $0)) }
        try writeLines(lines.joined(separator: "\n") + "\n", to: url)

        let result = try PerfShardReader.read(url: url)
        #expect(result.records.count == 5)
        #expect(result.skippedLineCount == 0)
        #expect(!result.hasTruncatedTail)

        let indices = try result.records.map { try $0.decodePayload(as: StorageSample.self).index }
        #expect(indices == [0, 1, 2, 3, 4])
    }

    @Test("末行被截断时保留前面所有记录，并标记截断")
    func recoversFromTruncatedTail() throws {
        let temp = TemporaryDirectory()
        let url = temp.url.appendingPathComponent("sample-000.jsonl")

        // 模拟进程被杀：最后一行写到一半
        let good = try (0..<3).map { try encodedLine(StorageSample(index: $0)) }
        let truncated = try encodedLine(StorageSample(index: 99)).prefix(20)
        try writeLines(good.joined(separator: "\n") + "\n" + truncated, to: url)

        let result = try PerfShardReader.read(url: url)

        // 前三条完好——崩溃前的数据往往最有价值，不能因为末尾半行就全丢
        #expect(result.records.count == 3)
        #expect(result.skippedLineCount == 1)
        #expect(result.hasTruncatedTail)
    }

    @Test("中间出现坏行时跳过并计数，不中断读取")
    func skipsCorruptedLinesInMiddle() throws {
        let temp = TemporaryDirectory()
        let url = temp.url.appendingPathComponent("sample-000.jsonl")

        var lines = try (0..<3).map { try encodedLine(StorageSample(index: $0)) }
        lines.insert("{not valid json", at: 1)
        lines.insert("", at: 3)   // 空行
        try writeLines(lines.joined(separator: "\n") + "\n", to: url)

        let result = try PerfShardReader.read(url: url)
        #expect(result.records.count == 3)
        #expect(result.skippedLineCount == 1)   // 空行不计为坏行
    }

    @Test("按 kind 过滤")
    func filtersByKind() throws {
        let temp = TemporaryDirectory()
        let url = temp.url.appendingPathComponent("mixed-000.jsonl")

        let lines = [
            try encodedLine(StorageSample(index: 1)),
            try encodedLine(HangSample(durationMs: 4200)),
            try encodedLine(StorageSample(index: 2)),
        ]
        try writeLines(lines.joined(separator: "\n") + "\n", to: url)

        let result = try PerfShardReader.read(
            url: url,
            filter: PerfRecordFilter(kinds: [HangSample.kind])
        )
        #expect(result.records.count == 1)
        #expect(result.records[0].kind == HangSample.kind)
    }

    @Test("按严重度过滤")
    func filtersBySeverity() throws {
        let temp = TemporaryDirectory()
        let url = temp.url.appendingPathComponent("sample-000.jsonl")

        let lines = [
            try encodedLine(StorageSample(index: 1), severity: .debug),
            try encodedLine(StorageSample(index: 2), severity: .warning),
            try encodedLine(StorageSample(index: 3), severity: .critical),
        ]
        try writeLines(lines.joined(separator: "\n") + "\n", to: url)

        let result = try PerfShardReader.read(
            url: url,
            filter: PerfRecordFilter(minimumSeverity: .warning)
        )
        #expect(result.records.count == 2)
    }

    @Test("跨越读取缓冲边界的行能被正确拼接")
    func handlesLinesSpanningChunkBoundary() throws {
        let temp = TemporaryDirectory()
        let url = temp.url.appendingPathComponent("sample-000.jsonl")

        let lines = try (0..<20).map {
            try encodedLine(StorageSample(index: $0, filler: String(repeating: "x", count: 200)))
        }
        try writeLines(lines.joined(separator: "\n") + "\n", to: url)

        // 故意用远小于单行长度的块大小，强制每行都跨越多个块
        let result = try PerfShardReader.read(url: url, chunkSize: 64)
        #expect(result.records.count == 20)
        #expect(result.skippedLineCount == 0)

        let indices = try result.records.map { try $0.decodePayload(as: StorageSample.self).index }
        #expect(indices == Array(0..<20))
    }
}
