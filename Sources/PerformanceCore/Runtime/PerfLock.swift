import os

/// `os_unfair_lock` 的安全封装。
///
/// 为什么不用标准库的 `Mutex`：它要求 iOS 18 / macOS 15，而本框架最低支持 iOS 15 / macOS 12。
///
/// 为什么用 `os_unfair_lock` 而不是 `NSLock` 或串行队列：
/// 这个锁会出现在主线程的 RunLoop 回调和 DisplayLink 回调里，临界区必须极短且无内核往返。
/// `os_unfair_lock` 在 Darwin 上带优先级捐赠，能避免主线程被低优先级采集线程阻塞导致的优先级反转。
///
/// 使用约束：临界区内**不得**分配内存、做 I/O、调用可能阻塞的 API，也不得递归加锁。
public final class PerfLock: @unchecked Sendable {
    /// 用堆上的指针而非存储属性，避免 `&property` 触发的独占性检查开销，
    /// 也避免结构体被复制后锁失效。
    private let unfairLock: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
    }

    deinit {
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    public func lock() {
        os_unfair_lock_lock(unfairLock)
    }

    public func unlock() {
        os_unfair_lock_unlock(unfairLock)
    }

    @inlinable
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
