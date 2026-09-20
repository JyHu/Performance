import Foundation

/// 有界的记录缓冲，连接「采集侧」与「落盘侧」。
///
/// ## 为什么需要它
///
/// 采集点可能在主线程的 RunLoop observer、CADisplayLink 回调这类关键路径上。
/// 上一版的 `EventStore.append` 注释写着「异步追加」，实现却是 `queue.sync`——
/// 被 31 处调用，其中就包括 RunLoop observer 和 DisplayLink 回调。
/// 结果是每记录一条数据，主线程就要做一次跨线程同步等待：**监控本身成了卡顿源**。
///
/// ## 设计约束
///
/// - `submit` 在临界区内只做一次 `append`（容量已预留，不触发扩容），无内存分配、无 I/O。
/// - `drain` 的替换缓冲在**加锁前**就备好，所以临界区也只是两次 O(1) 的引用赋值。
/// - 缓冲满时丢弃**新**记录并计数。丢弃是有界内存的必然代价，
///   但丢弃量本身会作为 `core.dropped` 指标落盘——数据缺口不能被误读成「这段时间没问题」。
public final class PerfRecordBuffer: @unchecked Sendable {
    private let lock = PerfLock()
    private let capacity: Int

    private var storage: ContiguousArray<PerfAnyRecord>
    private var droppedSinceLastDrain: UInt64 = 0
    private var droppedCumulative: UInt64 = 0

    public init(capacity: Int = 4096) {
        precondition(capacity > 0, "缓冲容量必须为正数")
        self.capacity = capacity
        var initial = ContiguousArray<PerfAnyRecord>()
        initial.reserveCapacity(capacity)
        self.storage = initial
    }

    /// 提交一条记录。非阻塞，可在任意线程（含主线程关键路径）调用。
    ///
    /// - Returns: 是否成功入队。`false` 表示缓冲已满、该条被丢弃。
    @discardableResult
    public func submit(_ record: PerfAnyRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard storage.count < capacity else {
            droppedSinceLastDrain &+= 1
            droppedCumulative &+= 1
            return false
        }
        storage.append(record)
        return true
    }

    /// 取走当前所有记录，并把缓冲重置为空。
    ///
    /// 替换用的空缓冲在加锁前分配，确保临界区内不发生 `malloc`。
    public func drain() -> Drained {
        // 锁外准备，临界区内只做引用赋值
        var replacement = ContiguousArray<PerfAnyRecord>()
        replacement.reserveCapacity(capacity)

        lock.lock()
        let records = storage
        storage = replacement
        let dropped = droppedSinceLastDrain
        let cumulative = droppedCumulative
        droppedSinceLastDrain = 0
        lock.unlock()

        return Drained(records: records, dropped: dropped, droppedCumulative: cumulative)
    }

    /// 当前积压条数，用于背压判断与自检。
    public var count: Int {
        lock.withLock { storage.count }
    }

    /// 累计丢弃条数。
    public var totalDropped: UInt64 {
        lock.withLock { droppedCumulative }
    }

    public struct Drained: Sendable {
        public let records: ContiguousArray<PerfAnyRecord>
        /// 上次 drain 以来丢弃的条数。
        public let dropped: UInt64
        /// 进程启动以来累计丢弃的条数。
        public let droppedCumulative: UInt64

        public var isEmpty: Bool { records.isEmpty && dropped == 0 }
    }
}
