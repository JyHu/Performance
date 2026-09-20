import Foundation
import PerformanceCore

/// 分片文件的命名与定位。
///
/// 布局：
/// ```
/// <root>/
/// ├── sessions/
/// │   ├── 20260920T103045-A1B2C3/
/// │   │   ├── manifest.json
/// │   │   ├── hang-000.jsonl          ← 当前正在写
/// │   │   ├── hang-001.jsonl
/// │   │   ├── rendering-000.jsonl.gz  ← 已归档
/// │   │   └── resource-000.jsonl
/// │   └── 20260919T221130-D4E5F6/
/// └── crash/
/// ```
///
/// 两条命名约定各自承担一个查询优化：
/// - **按 kind 大类分文件**：查 `hang.*` 时可以完全跳过 `resource-*.jsonl`。
/// - **session 目录名以时间戳开头**：目录按字典序排列即按时间排列，
///   做保留清理和时间范围过滤时不必读取每个目录的元信息。
///
/// 这两点合起来弥补了 JSONL 没有索引的短板。
public struct PerfShardLocator: Sendable {
    /// 数据根目录。
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 默认根目录：`<Caches>/Performance`。
    ///
    /// 放 Caches 而非 Documents 有两个理由：性能数据是可再生的诊断数据，
    /// 系统在磁盘吃紧时可以回收；且 Caches 不参与 iCloud 备份，
    /// 不会让用户的备份里塞满诊断日志。
    public static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            // 上一版这里是 `.first!`。取不到缓存目录虽然罕见，
            // 但让性能框架把宿主 app 崩掉是完全不可接受的。
            throw PerfStorageError.cachesDirectoryUnavailable
        }
        return caches.appendingPathComponent("Performance", isDirectory: true)
    }

    public var sessionsDirectory: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    public var crashDirectory: URL {
        root.appendingPathComponent("crash", isDirectory: true)
    }

    public func directory(for session: PerfSessionID) -> URL {
        sessionsDirectory.appendingPathComponent(session.rawValue, isDirectory: true)
    }

    public func manifestURL(for session: PerfSessionID) -> URL {
        directory(for: session).appendingPathComponent("manifest.json", isDirectory: false)
    }

    /// 分片文件名：`<大类>-<三位序号>.jsonl`。
    ///
    /// 序号补零到三位，保证字典序与数值序一致——
    /// 否则 `hang-10.jsonl` 会排在 `hang-2.jsonl` 前面，读取顺序就乱了。
    public func shardURL(session: PerfSessionID, group: String, index: Int) -> URL {
        directory(for: session)
            .appendingPathComponent(String(format: "%@-%03d.jsonl", group, index), isDirectory: false)
    }

    /// 归档（gzip）后的分片路径。
    public func archivedShardURL(session: PerfSessionID, group: String, index: Int) -> URL {
        let plain = shardURL(session: session, group: group, index: index)
        return plain.appendingPathExtension("gz")
    }
}

/// 解析出的分片信息。
public struct PerfShardDescriptor: Sendable, Hashable {
    public let url: URL
    public let group: String
    public let index: Int
    public let isArchived: Bool

    public init(url: URL, group: String, index: Int, isArchived: Bool) {
        self.url = url
        self.group = group
        self.index = index
        self.isArchived = isArchived
    }

    /// 从文件名反解。不符合命名约定时返回 nil。
    ///
    /// 目录里出现无法识别的文件不是错误——可能是其他工具留下的，
    /// 也可能是未来版本写的。跳过它们比报错更稳妥。
    public static func parse(url: URL) -> PerfShardDescriptor? {
        let name = url.lastPathComponent
        let isArchived = name.hasSuffix(".jsonl.gz")

        let suffix = isArchived ? ".jsonl.gz" : ".jsonl"
        guard name.hasSuffix(suffix) else { return nil }

        let stem = String(name.dropLast(suffix.count))
        guard let separator = stem.lastIndex(of: "-") else { return nil }

        let group = String(stem[stem.startIndex..<separator])
        guard !group.isEmpty,
              let index = Int(stem[stem.index(after: separator)...])
        else { return nil }

        return PerfShardDescriptor(url: url, group: group, index: index, isArchived: isArchived)
    }
}

public enum PerfStorageError: Error, Sendable, Equatable {
    case cachesDirectoryUnavailable
    case directoryCreationFailed(path: String, underlying: String)
    case fileOpenFailed(path: String, errno: Int32)
    case writeFailed(path: String, errno: Int32)
    case compressionFailed(path: String)
}
