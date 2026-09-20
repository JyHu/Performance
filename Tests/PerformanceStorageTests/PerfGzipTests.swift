import Foundation
import Testing

@testable import PerformanceStorage

@Suite("gzip 归档")
struct PerfGzipTests {
    @Test("压缩后可完整还原")
    func roundTrips() throws {
        let original = Data("""
        {"v":1,"k":"hang.anr","sev":"critical"}
        {"v":1,"k":"hang.anr","sev":"warning"}
        """.utf8)

        let compressed = try #require(PerfGzip.compress(original))
        let restored = try #require(PerfGzip.decompress(compressed))
        #expect(restored == original)
    }

    @Test("产出的是标准 gzip 格式，外部工具可直接解压")
    func producesStandardGzipContainer() throws {
        let compressed = try #require(PerfGzip.compress(Data(repeating: 0x41, count: 1_000)))

        // 10 字节标准头：magic + CM=deflate + FLG + MTIME + XFL + OS
        #expect(compressed[0] == 0x1F)
        #expect(compressed[1] == 0x8B)
        #expect(compressed[2] == 0x08)
        // 8 字节尾：CRC32 + ISIZE
        #expect(compressed.count > 18)
    }

    @Test("尾部记录的原始长度正确")
    func recordsOriginalSize() throws {
        let original = Data(repeating: 0x42, count: 12_345)
        let compressed = try #require(PerfGzip.compress(original))

        let sizeBytes = compressed.suffix(4)
        let recordedSize = sizeBytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(recordedSize == 12_345)
    }

    @Test("重复内容被有效压缩")
    func compressesRepetitiveData() throws {
        let original = Data(String(repeating: #"{"k":"resource.cpu","p":{"v":42}}"#, count: 500).utf8)
        let compressed = try #require(PerfGzip.compress(original))

        // JSONL 高度重复，压缩比应当很可观
        #expect(compressed.count < original.count / 5)
    }

    @Test("CRC 校验失败时返回 nil，而不是给出半截数据")
    func rejectsCorruptedArchive() throws {
        var compressed = try #require(PerfGzip.compress(Data(repeating: 0x43, count: 500)))

        // 翻转压缩数据中间的一个字节
        let midpoint = compressed.count / 2
        compressed[midpoint] ^= 0xFF

        // 损坏的归档必须明确失败：基于残缺数据排查比没有数据更糟
        #expect(PerfGzip.decompress(compressed) == nil)
    }

    @Test("非 gzip 输入被拒绝")
    func rejectsNonGzipInput() {
        #expect(PerfGzip.decompress(Data("plain text, not gzip at all".utf8)) == nil)
        #expect(PerfGzip.decompress(Data()) == nil)
    }

    @Test("空输入不产出归档")
    func rejectsEmptyInput() {
        #expect(PerfGzip.compress(Data()) == nil)
    }

    @Test("CRC32 与已知值一致")
    func matchesKnownCRC32() {
        // "123456789" 的 CRC-32 标准测试向量
        #expect(PerfGzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
