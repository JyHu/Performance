import Compression
import Foundation

/// gzip 压缩与解压。
///
/// ## 为什么要自己拼 gzip 容器
///
/// 系统 `Compression` 框架的 `COMPRESSION_ZLIB` 实际产出的是**裸 DEFLATE**
/// 流（RFC 1951），没有任何容器头。直接把它存成 `.gz` 会得到一个
/// `gunzip` 打不开的文件。
///
/// 而「能用 `zcat foo.jsonl.gz | grep anr` 直接看」对一个排查框架是有实质价值的：
/// 拿到用户导出的归档，不需要任何专用工具就能开始定位问题。
/// 所以这里在裸 DEFLATE 外面补上标准的 10 字节头和 8 字节尾。
///
/// 整个实现只依赖系统框架，不引入任何三方依赖。
public enum PerfGzip {
    /// gzip 头：magic(2) + CM(1) + FLG(1) + MTIME(4) + XFL(1) + OS(1)。
    ///
    /// MTIME 固定为 0 而不是真实时间：归档时间本身不是有用信息，
    /// 而固定值让相同输入产出相同字节，便于测试与去重。
    private static let header: [UInt8] = [
        0x1F, 0x8B,             // magic
        0x08,                   // CM = deflate
        0x00,                   // FLG = 无额外字段
        0x00, 0x00, 0x00, 0x00, // MTIME = 0
        0x00,                   // XFL
        0x03,                   // OS = Unix
    ]

    /// 压缩为标准 gzip 格式。
    public static func compress(_ source: Data) -> Data? {
        guard !source.isEmpty else { return nil }

        guard let deflated = rawDeflate(source) else { return nil }

        var output = Data(header)
        output.append(deflated)
        appendLittleEndian(crc32(source), to: &output)
        // ISIZE 按规范是原始长度对 2^32 取模
        appendLittleEndian(UInt32(truncatingIfNeeded: source.count), to: &output)
        return output
    }

    /// 解压标准 gzip 格式，并校验 CRC。
    ///
    /// 校验失败返回 nil：归档文件损坏时给出半截数据，
    /// 比明确告知「这个文件读不了」更糟——那会让排查建立在错误数据上。
    public static func decompress(_ source: Data) -> Data? {
        guard source.count > 18,
              source[source.startIndex] == 0x1F,
              source[source.startIndex + 1] == 0x8B,
              source[source.startIndex + 2] == 0x08
        else { return nil }

        let flags = source[source.startIndex + 3]
        var cursor = source.startIndex + 10

        // FEXTRA：2 字节长度 + 内容
        if flags & 0x04 != 0 {
            guard cursor + 2 <= source.endIndex else { return nil }
            let length = Int(source[cursor]) | (Int(source[cursor + 1]) << 8)
            cursor += 2 + length
        }
        // FNAME / FCOMMENT：NUL 结尾的字符串
        for mask in [UInt8(0x08), UInt8(0x10)] where flags & mask != 0 {
            guard let terminator = source[cursor...].firstIndex(of: 0) else { return nil }
            cursor = terminator + 1
        }
        // FHCRC：2 字节头部校验
        if flags & 0x02 != 0 {
            cursor += 2
        }

        let trailerStart = source.endIndex - 8
        guard cursor < trailerStart else { return nil }

        let expectedCRC = readLittleEndian(source, at: trailerStart)
        let expectedSize = readLittleEndian(source, at: trailerStart + 4)

        let deflated = source[cursor..<trailerStart]
        guard let inflated = rawInflate(Data(deflated), expectedSize: Int(expectedSize)) else {
            return nil
        }
        guard crc32(inflated) == expectedCRC else { return nil }

        return inflated
    }

    // MARK: - 裸 DEFLATE

    private static func rawDeflate(_ source: Data) -> Data? {
        // 不可压缩的输入经 DEFLATE 后会略微变大，预留余量
        let capacity = source.count + source.count / 100 + 64
        var destination = [UInt8](repeating: 0, count: capacity)

        let written = source.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                &destination, capacity,
                sourceBase, source.count,
                nil, COMPRESSION_ZLIB
            )
        }

        guard written > 0 else { return nil }
        return Data(destination[0..<written])
    }

    private static func rawInflate(_ source: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var destination = [UInt8](repeating: 0, count: expectedSize)

        let written = source.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                &destination, expectedSize,
                sourceBase, source.count,
                nil, COMPRESSION_ZLIB
            )
        }

        guard written == expectedSize else { return nil }
        return Data(destination)
    }

    // MARK: - CRC32

    /// CRC-32（IEEE 802.3 多项式 0xEDB88320），gzip 尾部校验用。
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                // 逐位算而不建查找表：调用频率低（每个分片一次），
                // 省下 1KB 常驻内存比省那点 CPU 更划算。
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - 字节序

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readLittleEndian(_ data: Data, at index: Data.Index) -> UInt32 {
        UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }
}
