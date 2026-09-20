import Foundation

/// 可在运行时安全替换的配置容器。
///
/// 监测器本身是 actor，内部状态由编译器保证隔离。但有些采集点跑在
/// actor 之外——C 回调（`CFRunLoopObserver`、`CVDisplayLink`）、
/// signal handler、业务方在任意线程发起的手动打点——那里无法 `await`，
/// 又需要读到最新阈值。这个盒子专门服务这些场景。
///
/// 上一版在这里踩了两个相反的坑：一部分模块在 init 时把阈值拷成自己的 `let`，
/// 启动后改配置完全无效；另一部分（`PMIOTracker`）直接从后台线程读
/// `nonisolated(unsafe)` 单例的 `var`，是明确的数据竞争。
public final class PerfOptionsBox<Options: Sendable>: @unchecked Sendable {
    private let lock = PerfLock()
    private var storage: Options

    public init(_ initial: Options) {
        self.storage = initial
    }

    /// 读取当前配置。可在任意线程调用。
    public var value: Options {
        lock.withLock { storage }
    }

    /// 整体替换配置。
    public func update(_ newValue: Options) {
        lock.withLock { storage = newValue }
    }

    /// 就地修改配置。
    public func mutate(_ body: (inout Options) -> Void) {
        lock.withLock { body(&storage) }
    }

    /// 只读取一个字段，避免整体拷贝。
    public func read<T>(_ keyPath: KeyPath<Options, T>) -> T {
        lock.withLock { storage[keyPath: keyPath] }
    }
}
