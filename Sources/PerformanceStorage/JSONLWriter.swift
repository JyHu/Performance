import Foundation
import PerformanceCore

/// 单个 kind 大类的分片写入器。
///
/// ## 为什么用 POSIX `write(2)` 而不是 `FileHandle`
///
/// - `FileHandle` 的写入在出错时抛 Objective-C 异常，Swift 里**捕获不到**，
///   直接导致进程终止。磁盘写满是完全可能发生的，性能框架不该因此崩掉宿主 app。
/// - `write(2)` 没有额外的缓冲层，批量写入的时机完全由我们掌握。
///
/// ## 为什么用 `O_APPEND`
///
/// 内核保证「移动文件偏移 + 写入」这两步对普通文件是原子的。
/// 这样即使同一目录被多个写入者（例如 app 与 extension）同时追加，
/// 也不会出现内容交错，最多是记录之间的顺序打乱。
public final class PerfShardWriter {
    private let locator: PerfShardLocator
    private let session: PerfSessionID
    private let group: String
    private let maxShardBytes: UInt64
    private let fileManager: FileManager
    private let log: PerfLog

    private var currentIndex: Int
    private var fileDescriptor: Int32 = -1
    private var currentBytes: UInt64 = 0

    /// 已完成（已滚动过去、可归档）的分片序号。
    public private(set) var completedShardIndices: [Int] = []

    public init(
        locator: PerfShardLocator,
        session: PerfSessionID,
        group: String,
        maxShardBytes: PerfByteCount,
        fileManager: FileManager = .default,
        log: PerfLog = .disabled
    ) throws {
        self.locator = locator
        self.session = session
        self.group = group
        self.maxShardBytes = max(1, maxShardBytes.bytes)
        self.fileManager = fileManager
        self.log = log

        let directory = locator.directory(for: session)
        try Self.ensureDirectory(directory, fileManager: fileManager)

        // 从已有文件里接着写，而不是从 0 开始覆盖。
        // 写入器可能在一次 session 内被重建（配置热更、暂停后恢复）。
        self.currentIndex = Self.highestExistingIndex(
            in: directory,
            group: group,
            fileManager: fileManager
        ) ?? 0
    }

    deinit {
        closeCurrentFile()
    }

    /// 追加一批已编码的记录。每条记录一行，行尾补 `\n`。
    ///
    /// - Parameter lines: 每个元素是一条记录的 JSON 字节，**不含**换行符。
    public func append(lines: [Data]) throws {
        guard !lines.isEmpty else { return }

        var batch = Data()
        batch.reserveCapacity(lines.reduce(0) { $0 + $1.count + 1 })

        for line in lines {
            let lineSize = UInt64(line.count + 1)

            // 单条记录就超过分片上限：给它独占一个分片。
            // 不这样处理会陷入「滚动→仍然超限→再滚动」的死循环。
            if lineSize > maxShardBytes {
                try flush(&batch)
                try rollToNewShard()
                try writeToCurrentFile(line + Self.newline)
                log.warning("单条记录 \(lineSize) 字节超过分片上限 \(maxShardBytes)，已独占一个分片")
                try rollToNewShard()
                continue
            }

            if currentBytes + UInt64(batch.count) + lineSize > maxShardBytes {
                try flush(&batch)
                try rollToNewShard()
            }

            batch.append(line)
            batch.append(Self.newline)
        }

        try flush(&batch)
    }

    /// 关闭当前分片。后续 `append` 会重新打开。
    public func close() {
        closeCurrentFile()
    }

    /// 当前正在写入的分片路径。
    public var currentShardURL: URL {
        locator.shardURL(session: session, group: group, index: currentIndex)
    }

    // MARK: - 内部

    private static let newline = Data([0x0A])

    private func flush(_ batch: inout Data) throws {
        guard !batch.isEmpty else { return }
        try writeToCurrentFile(batch)
        batch.removeAll(keepingCapacity: true)
    }

    private func writeToCurrentFile(_ data: Data) throws {
        if fileDescriptor < 0 {
            try openCurrentFile()
        }
        try Self.writeAll(data, to: fileDescriptor, path: currentShardURL.path)
        currentBytes += UInt64(data.count)
    }

    private func openCurrentFile() throws {
        let url = currentShardURL
        let descriptor = url.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw PerfStorageError.fileOpenFailed(path: url.path, errno: errno)
        }
        fileDescriptor = descriptor

        // 续写已有文件时要接上它当前的大小，否则滚动阈值会算错
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        currentBytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func closeCurrentFile() {
        guard fileDescriptor >= 0 else { return }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    private func rollToNewShard() throws {
        // 只有真正写过内容的分片才算「已完成」，避免归档空文件
        if currentBytes > 0 {
            completedShardIndices.append(currentIndex)
        }
        closeCurrentFile()
        currentIndex += 1
        currentBytes = 0
    }

    /// 取走已完成分片的序号，交给归档流程。
    public func takeCompletedShardIndices() -> [Int] {
        let result = completedShardIndices
        completedShardIndices.removeAll()
        return result
    }

    // MARK: - 辅助

    /// 循环写入直到全部落盘。
    ///
    /// `write(2)` 有两种「不算失败但没写完」的情况必须处理：
    /// 返回值小于请求长度（部分写入），以及被信号打断返回 `EINTR`。
    /// 不处理这两点会导致文件里出现半截 JSON。
    static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(descriptor, base + offset, rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw PerfStorageError.writeFailed(path: path, errno: errno)
                }
                offset += written
            }
        }
    }

    static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw PerfStorageError.directoryCreationFailed(
                path: url.path,
                underlying: error.localizedDescription
            )
        }
    }

    static func highestExistingIndex(
        in directory: URL,
        group: String,
        fileManager: FileManager
    ) -> Int? {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        return contents
            .compactMap(PerfShardDescriptor.parse)
            .filter { $0.group == group }
            .map(\.index)
            .max()
    }
}
