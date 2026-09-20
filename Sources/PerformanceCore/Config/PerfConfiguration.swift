import Foundation

/// 持久化相关设置。
public struct PerfStorageOptions: Sendable {
    /// 根目录。nil 表示使用 `<Caches>/Performance`。
    ///
    /// 放 Caches 而非 Documents：性能数据是可再生的诊断数据，
    /// 系统在磁盘紧张时可以回收，也不该被 iCloud 备份。
    public var directory: URL?

    /// 单个分片文件的大小上限，超过后滚动到下一个分片。
    public var maxShardBytes: PerfByteCount

    /// 整个性能数据目录的总配额。超出后从最旧的 session 开始整体删除。
    ///
    /// 上一版完全没有配额：上传失败的文件永久留存并每 30 秒重传一次，
    /// 唯一的终止条件是磁盘写满。
    public var totalQuota: PerfByteCount

    /// 常规数据的保留时长。
    public var retention: PerfDuration

    /// 崩溃报告的保留时长。比常规数据长得多——
    /// 崩溃是低频高价值事件，用户可能隔很久才来报障。
    public var crashRetention: PerfDuration

    /// 落盘节奏：攒够这么久就写一次。
    public var flushInterval: PerfDuration

    /// 落盘节奏：攒够这么多条就写一次。两个条件任一满足即触发。
    public var flushRecordCount: Int

    /// 是否对非当前 session 的分片做 gzip 归档。
    /// 用系统 `Compression` 框架，无三方依赖，典型压缩比 5~8 倍。
    public var compressArchivedShards: Bool

    public init(
        directory: URL? = nil,
        maxShardBytes: PerfByteCount = .megabytes(2),
        totalQuota: PerfByteCount = .megabytes(50),
        retention: PerfDuration = .days(7),
        crashRetention: PerfDuration = .days(30),
        flushInterval: PerfDuration = .seconds(5),
        flushRecordCount: Int = 256,
        compressArchivedShards: Bool = true
    ) {
        self.directory = directory
        self.maxShardBytes = maxShardBytes
        self.totalQuota = totalQuota
        self.retention = retention
        self.crashRetention = crashRetention
        self.flushInterval = flushInterval
        self.flushRecordCount = flushRecordCount
        self.compressArchivedShards = compressArchivedShards
    }
}

/// 采集→落盘管道的设置。
public struct PerfPipelineOptions: Sendable {
    /// 环形缓冲容量（条）。满了会丢弃新记录并计入 `core.dropped`。
    ///
    /// 这个值是「内存占用」与「突发场景下的数据完整度」之间的权衡。
    /// 4096 条在典型载荷下约占 1~2MB。
    public var bufferCapacity: Int

    /// 从缓冲取数据的周期。
    public var drainInterval: PerfDuration

    /// 低于此严重度的记录直接丢弃，不进缓冲。
    ///
    /// 生产环境设为 `.info` 可以滤掉 `.debug` 级别的高频数据。
    public var minimumSeverity: PerfSeverity

    public init(
        bufferCapacity: Int = 4096,
        drainInterval: PerfDuration = .seconds(1),
        minimumSeverity: PerfSeverity = .info
    ) {
        self.bufferCapacity = bufferCapacity
        self.drainInterval = drainInterval
        self.minimumSeverity = minimumSeverity
    }
}

/// 框架的完整配置。
///
/// 与上一版 `PMConfig` 的根本区别：这里**没有**任何监测器的具体阈值字段。
/// 那个 95 行、50 多个字段的扁平 struct 把所有模块的参数挤在一起
/// （`enableSignpost`、`mainThreadThresholdMs`、`ioSlowThresholdMs`、`uploadURL`…），
/// 加一个监测项要同时改配置、改门面属性、改 start、改 stop 四处。
///
/// 这里每个监测器的参数由它自己的 `Options` 承载，配置只负责编排：
///
/// ```swift
/// var config = PerfConfiguration()
/// config.enable(PerfHangMonitor.self) { $0.anrThreshold = .seconds(3) }
/// config.enable(PerfResourceMonitor.self) { $0.interval = .seconds(1) }
/// config.storage.totalQuota = .megabytes(20)
/// ```
public struct PerfConfiguration: Sendable {
    public var storage: PerfStorageOptions
    public var pipeline: PerfPipelineOptions
    public var redaction: PerfRedactionPolicy

    /// 框架自身的诊断日志开关。不影响性能数据采集。
    public var isLoggingEnabled: Bool

    /// 采样调度器的基频。所有监测器的采样周期都会对齐到它的整数倍。
    public var baseSamplingInterval: PerfDuration

    /// 已启用的监测器。按注册顺序启动、逆序停止。
    public private(set) var registrations: [PerfMonitorRegistration]

    public init(
        storage: PerfStorageOptions = PerfStorageOptions(),
        pipeline: PerfPipelineOptions = PerfPipelineOptions(),
        redaction: PerfRedactionPolicy = .default,
        isLoggingEnabled: Bool = false,
        baseSamplingInterval: PerfDuration = .milliseconds(100)
    ) {
        self.storage = storage
        self.pipeline = pipeline
        self.redaction = redaction
        self.isLoggingEnabled = isLoggingEnabled
        self.baseSamplingInterval = baseSamplingInterval
        self.registrations = []
    }

    // MARK: - 编排

    /// 启用一个监测器。重复启用会覆盖先前的配置。
    ///
    /// - Parameter configure: 在默认配置基础上修改需要的字段。
    public mutating func enable<M: PerfMonitor>(
        _ type: M.Type,
        configure: (inout M.Options) -> Void = { _ in }
    ) {
        var options = M.Options()
        configure(&options)

        let registration = PerfMonitorRegistration(type: type, options: options)
        if let index = registrations.firstIndex(where: { $0.descriptor.id == M.descriptor.id }) {
            registrations[index] = registration
        } else {
            registrations.append(registration)
        }
    }

    /// 停用一个监测器。
    public mutating func disable<M: PerfMonitor>(_ type: M.Type) {
        registrations.removeAll { $0.descriptor.id == M.descriptor.id }
    }

    public func isEnabled<M: PerfMonitor>(_ type: M.Type) -> Bool {
        registrations.contains { $0.descriptor.id == M.descriptor.id }
    }

    /// 已启用监测器的标识列表，写入 session manifest。
    public var enabledMonitorIDs: [String] {
        registrations.map(\.descriptor.id.rawValue)
    }

    // MARK: - 自检

    /// 启动前的配置检查。
    ///
    /// 返回的是**告警**而非错误：配置有瑕疵时应当降级运行并提示，
    /// 而不是让 app 因为性能框架配置不当而起不来。
    public func validate() -> [Warning] {
        var warnings: [Warning] = []

        // 平台不匹配的监测器会静默空转，必须提前告知
        for registration in registrations
        where !registration.descriptor.platforms.isAvailableOnCurrentPlatform {
            warnings.append(.unsupportedPlatform(registration.descriptor.id))
        }

        // 两个监测器产出同一种 kind 会让数据来源无法区分
        var kindOwners: [PerfKind: PerfMonitorID] = [:]
        for registration in registrations {
            for kind in registration.descriptor.kinds {
                if let existing = kindOwners[kind] {
                    warnings.append(.duplicateKind(kind, existing, registration.descriptor.id))
                } else {
                    kindOwners[kind] = registration.descriptor.id
                }
            }
        }

        if storage.maxShardBytes > storage.totalQuota {
            warnings.append(.shardLargerThanQuota)
        }
        if pipeline.bufferCapacity <= 0 {
            warnings.append(.invalidBufferCapacity)
        }

        return warnings
    }

    public enum Warning: Sendable, Hashable, CustomStringConvertible {
        case unsupportedPlatform(PerfMonitorID)
        case duplicateKind(PerfKind, PerfMonitorID, PerfMonitorID)
        case shardLargerThanQuota
        case invalidBufferCapacity

        public var description: String {
            switch self {
            case .unsupportedPlatform(let id):
                "监测器 \(id) 不支持当前平台，已跳过"
            case .duplicateKind(let kind, let first, let second):
                "监测器 \(first) 与 \(second) 都声明产出 \(kind)，数据来源将无法区分"
            case .shardLargerThanQuota:
                "单分片上限大于总配额，分片将无法完整写出"
            case .invalidBufferCapacity:
                "缓冲容量必须为正数"
            }
        }
    }
}
