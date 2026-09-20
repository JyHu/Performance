import Foundation
import PerformanceCore

/// 本地持久化门面：写入、归档、查询、清理。
public actor PerfStore {
    public let session: PerfSessionID
    public let locator: PerfShardLocator

    private let options: PerfStorageOptions
    /// 落盘前应用的脱敏策略。
    ///
    /// 由外部注入而不是自己持有默认值：脱敏策略在 `PerfConfiguration`
    /// 里只有一个来源，避免出现「配置里设了严格模式，落盘却用的默认模式」。
    private let redactionPolicy: PerfRedactionPolicy
    private let fileManager: FileManager
    private let log: PerfLog
    private let encoder = JSONEncoder()

    /// 每个 kind 大类一个写入器。
    private var writers: [String: PerfShardWriter] = [:]
    private var manifest: PerfSessionManifest

    /// 累计写入条数与字节数，用于自检。
    public private(set) var writtenRecordCount: UInt64 = 0
    public private(set) var writtenByteCount: UInt64 = 0
    /// 编码失败的条数。
    public private(set) var encodingFailureCount: UInt64 = 0

    public init(
        session: PerfSessionID,
        options: PerfStorageOptions,
        redaction: PerfRedactionPolicy = .default,
        device: PerfDeviceInfo = .current(),
        enabledMonitors: [String] = [],
        startedAt: Date = Date(),
        fileManager: FileManager = .default,
        log: PerfLog = .disabled
    ) throws {
        self.session = session
        self.options = options
        self.redactionPolicy = redaction
        self.fileManager = fileManager
        self.log = log

        let root = try options.directory ?? PerfShardLocator.defaultRoot(fileManager: fileManager)
        self.locator = PerfShardLocator(root: root)

        self.manifest = PerfSessionManifest(
            sessionID: session,
            startedAt: startedAt,
            device: device,
            enabledMonitors: enabledMonitors
        )

        try PerfShardWriter.ensureDirectory(locator.directory(for: session), fileManager: fileManager)
        try PerfShardWriter.ensureDirectory(locator.crashDirectory, fileManager: fileManager)
        try Self.write(manifest, to: locator.manifestURL(for: session))
    }

    // MARK: - 写入

    /// 写入一批记录。
    ///
    /// 按 kind 大类分流到不同分片文件——这是查询时能整片跳过的前提。
    public func append(_ records: some Sequence<PerfAnyRecord>) {
        var grouped: [String: [Data]] = [:]

        for record in records {
            let redacted = record.redacted(using: redactionPolicy)
            guard let line = try? encoder.encode(redacted) else {
                // 单条编码失败不该拖垮整批。计数上报，让问题可被发现。
                encodingFailureCount += 1
                continue
            }
            grouped[record.kind.group, default: []].append(line)
        }

        for (group, lines) in grouped {
            do {
                let writer = try writer(for: group)
                try writer.append(lines: lines)
                writtenRecordCount += UInt64(lines.count)
                writtenByteCount += UInt64(lines.reduce(0) { $0 + $1.count + 1 })
            } catch {
                log.error("写入分片 \(group) 失败：\(error)")
            }
        }

        archiveCompletedShards()
    }

    /// 关闭所有分片文件句柄。
    public func closeShards() {
        for writer in writers.values {
            writer.close()
        }
    }

    /// 标记 session 正常结束。
    ///
    /// manifest 里 `endedAt` 为 nil 即表示进程是被杀掉的——
    /// 这本身就是一条有价值的信息：崩溃、OOM、看门狗终止都会留下这个痕迹。
    public func finalizeSession(at date: Date = Date()) {
        manifest.endedAt = date
        try? writeManifest()
        closeShards()
    }

    // MARK: - 查询

    /// 本地存在的全部 session，按时间由新到旧。
    public func availableSessions() -> [PerfSessionID] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: locator.sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { PerfSessionID(rawValue: $0.lastPathComponent) }
            // session 目录名以时间戳开头，字典序倒排即时间倒排
            .sorted { $0.rawValue > $1.rawValue }
    }

    public func manifest(for session: PerfSessionID) -> PerfSessionManifest? {
        guard let data = try? Data(contentsOf: locator.manifestURL(for: session)) else { return nil }
        return try? JSONDecoder().decode(PerfSessionManifest.self, from: data)
    }

    /// 查询某个 session 的记录。
    public func records(
        in session: PerfSessionID,
        matching filter: PerfRecordFilter = .all
    ) -> PerfQueryResult {
        var result = PerfQueryResult()

        for shard in shards(in: session, matching: filter) {
            do {
                let read = try PerfShardReader.read(url: shard.url, filter: filter)
                result.records.append(contentsOf: read.records)
                result.skippedLineCount += read.skippedLineCount
                if read.hasTruncatedTail {
                    result.truncatedShards.append(shard.url.lastPathComponent)
                }
            } catch {
                log.error("读取分片 \(shard.url.lastPathComponent) 失败：\(error)")
                result.unreadableShards.append(shard.url.lastPathComponent)
            }
        }

        result.records.sort { $0.timestamp < $1.timestamp }
        return result
    }

    /// 跨全部 session 查询，按时间由新到旧遍历。
    public func records(matching filter: PerfRecordFilter = .all) -> PerfQueryResult {
        var combined = PerfQueryResult()
        for session in availableSessions() {
            let partial = records(in: session, matching: filter)
            combined.records.append(contentsOf: partial.records)
            combined.skippedLineCount += partial.skippedLineCount
            combined.truncatedShards.append(contentsOf: partial.truncatedShards)
            combined.unreadableShards.append(contentsOf: partial.unreadableShards)
        }
        combined.records.sort { $0.timestamp < $1.timestamp }
        return combined
    }

    /// 列出 session 下需要读取的分片。
    ///
    /// 按 filter 声明的 kind 大类过滤文件名，不匹配的文件根本不会被打开。
    func shards(in session: PerfSessionID, matching filter: PerfRecordFilter) -> [PerfShardDescriptor] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: locator.directory(for: session),
            includingPropertiesForKeys: nil
        )) ?? []

        let requiredGroups = filter.requiredGroups
        return contents
            .compactMap(PerfShardDescriptor.parse)
            .filter { requiredGroups?.contains($0.group) ?? true }
            .sorted { ($0.group, $0.index) < ($1.group, $1.index) }
    }

    // MARK: - 导出

    /// 把匹配的记录打包成单个 gzip 压缩的 JSONL 文件。
    ///
    /// 产物可以直接附到 bug 单上，接收方用 `zcat` 就能看，不需要任何专用工具。
    @discardableResult
    public func exportArchive(
        matching filter: PerfRecordFilter = .all,
        to destination: URL
    ) throws -> URL {
        let result = records(matching: filter)

        var payload = Data()
        for record in result.records {
            payload.append(record.lineData)
            payload.append(0x0A)
        }

        guard let compressed = PerfGzip.compress(payload) else {
            throw PerfStorageError.compressionFailed(path: destination.path)
        }

        try PerfShardWriter.ensureDirectory(
            destination.deletingLastPathComponent(),
            fileManager: fileManager
        )
        try compressed.write(to: destination, options: .atomic)
        log.info("导出 \(result.records.count) 条记录到 \(destination.lastPathComponent)")
        return destination
    }

    // MARK: - 清理

    @discardableResult
    public func enforceRetention(now: Date = Date()) -> PerfRetentionReport {
        let enforcer = PerfRetentionEnforcer(
            locator: locator,
            policy: PerfRetentionPolicy(storage: options),
            fileManager: fileManager,
            log: log
        )
        return enforcer.enforce(currentSession: session, now: now)
    }

    public func currentDiskUsage() -> PerfByteCount {
        PerfRetentionEnforcer(
            locator: locator,
            policy: PerfRetentionPolicy(storage: options),
            fileManager: fileManager,
            log: log
        ).currentUsage()
    }

    // MARK: - 内部

    private func writer(for group: String) throws -> PerfShardWriter {
        if let existing = writers[group] { return existing }
        let created = try PerfShardWriter(
            locator: locator,
            session: session,
            group: group,
            maxShardBytes: options.maxShardBytes,
            fileManager: fileManager,
            log: log
        )
        writers[group] = created
        return created
    }

    /// 把已滚动过去的分片压缩归档。
    ///
    /// 只归档**已完成**的分片，正在写入的那个不动——
    /// 压缩一个还在被 append 的文件会得到一份注定不完整的快照。
    private func archiveCompletedShards() {
        guard options.compressArchivedShards else { return }

        for (group, writer) in writers {
            for index in writer.takeCompletedShardIndices() {
                let plain = locator.shardURL(session: session, group: group, index: index)
                let archived = locator.archivedShardURL(session: session, group: group, index: index)

                guard let raw = try? Data(contentsOf: plain),
                      let compressed = PerfGzip.compress(raw)
                else {
                    log.warning("归档分片 \(plain.lastPathComponent) 失败，保留原文件")
                    continue
                }

                do {
                    try compressed.write(to: archived, options: .atomic)
                    try fileManager.removeItem(at: plain)
                } catch {
                    // 归档失败不是致命问题：原文件还在，数据没丢。
                    // 但如果 .gz 已经写出去了，必须清掉，否则同一份数据会被读两遍。
                    try? fileManager.removeItem(at: archived)
                    log.warning("归档分片 \(plain.lastPathComponent) 失败：\(error)")
                }
            }
        }
    }

    private func writeManifest() throws {
        try Self.write(manifest, to: locator.manifestURL(for: session))
    }

    /// `nonisolated` 以便 `init` 里也能调用。
    ///
    /// manifest 要在 session 目录建好的**第一时间**写出去：
    /// 进程随时可能被杀，没有 manifest 的 session 目录无法判断设备与 app 版本，
    /// 里面的数据价值会大打折扣。
    private nonisolated static func write(_ manifest: PerfSessionManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }
}

/// 查询结果。
public struct PerfQueryResult: Sendable {
    public var records: [PerfRawRecord] = []
    /// 解析失败被跳过的行数。
    public var skippedLineCount: Int = 0
    /// 末尾被截断的分片（通常是进程被杀留下的）。
    public var truncatedShards: [String] = []
    /// 完全读不出来的分片。
    public var unreadableShards: [String] = []

    public init(
        records: [PerfRawRecord] = [],
        skippedLineCount: Int = 0,
        truncatedShards: [String] = [],
        unreadableShards: [String] = []
    ) {
        self.records = records
        self.skippedLineCount = skippedLineCount
        self.truncatedShards = truncatedShards
        self.unreadableShards = unreadableShards
    }

    public var isEmpty: Bool { records.isEmpty }

    /// 数据是否完整。有跳过行或不可读分片时为 false。
    ///
    /// 查询结果必须能自述完整性——基于残缺数据得出的性能结论
    /// 比没有结论更危险。
    public var isComplete: Bool {
        skippedLineCount == 0 && unreadableShards.isEmpty
    }
}
