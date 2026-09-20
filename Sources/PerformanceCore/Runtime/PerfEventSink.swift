import Foundation

/// 性能数据离开采集器的**唯一**出口。
///
/// 刻意设计成同步、非 throwing、非 async 的方法：采集点可能是 RunLoop observer
/// 或 DisplayLink 回调，那里既不能 `await`，也不能容忍抛错处理的分支开销。
/// 失败（缓冲满）在实现内部静默计数，不向采集侧传播。
///
/// 采集 target 只依赖这个协议，**不依赖 `PerfStorage`**。
/// 这保证了采集层与存储层解耦：换持久化方案不需要改任何一个采集器。
public protocol PerfEventSink: Sendable {
    func submit(_ record: PerfAnyRecord)
}

/// 直接写入缓冲的 sink，生产环境使用。
public struct PerfBufferSink: PerfEventSink {
    private let buffer: PerfRecordBuffer

    public init(buffer: PerfRecordBuffer) {
        self.buffer = buffer
    }

    public func submit(_ record: PerfAnyRecord) {
        buffer.submit(record)
    }
}

/// 丢弃一切的 sink，供压测对照和禁用场景使用。
public struct PerfNullSink: PerfEventSink {
    public init() {}
    public func submit(_ record: PerfAnyRecord) {}
}

/// 收集到内存供断言的 sink，供测试使用。
public final class PerfCollectingSink: PerfEventSink, @unchecked Sendable {
    private let lock = PerfLock()
    private var storage: [PerfAnyRecord] = []

    public init() {}

    public func submit(_ record: PerfAnyRecord) {
        lock.withLock { storage.append(record) }
    }

    public var records: [PerfAnyRecord] {
        lock.withLock { storage }
    }

    public func records(ofKind kind: PerfKind) -> [PerfAnyRecord] {
        lock.withLock { storage.filter { $0.kind == kind } }
    }

    /// 取出某个类型的全部载荷，类型不匹配的记录会被跳过。
    public func payloads<P: PerfPayload>(of type: P.Type) -> [P] {
        lock.withLock { storage.compactMap { $0.payload(as: P.self) } }
    }

    public func reset() {
        lock.withLock { storage.removeAll() }
    }
}
