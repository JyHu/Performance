import Foundation

/// 监测器的配置项。
///
/// 每个监测器定义自己的 `Options`，而不是往一个全局配置对象里加字段。
/// 上一版的 `PMConfig` 是 95 行、50 多个字段的扁平 struct，
/// 所有模块的阈值挤在一起，改任何一个都要重新理解全部。
public protocol PerfMonitorOptions: Sendable {
    /// 默认值。调用方只需覆盖关心的字段。
    init()
}

/// 性能监测器。
///
/// ## 为什么是 `Actor`
///
/// 监测器几乎都持有可变状态（上次采样值、连续超阈值计数、进行中的 span），
/// 而这些状态会被定时器回调、系统通知、业务方调用从不同线程触碰。
/// 用 actor 让编译器来保证隔离，而不是像上一版那样混用 `NSLock`、串行队列，
/// 再靠 10 处 `nonisolated(unsafe)` 和 5 处 `@unchecked Sendable` 来绕过检查。
///
/// ## 为什么依赖都从 `context` 注入
///
/// 监测器不自己创建定时器、不自己拿单例、不自己碰文件系统——
/// 全部能力经由 `PerfMonitorContext` 传入。这让每个监测器都能在测试里
/// 配上手动时钟和手动调度器，把「模拟 30 秒采样」变成 30 次同步调用。
public protocol PerfMonitor: Actor {
    associatedtype Options: PerfMonitorOptions

    /// 静态元信息。`nonisolated` 以便在不启动监测器的情况下查询。
    nonisolated static var descriptor: PerfMonitorDescriptor { get }

    init(options: Options, context: PerfMonitorContext)

    /// 开始采集。重复调用应当是幂等的。
    func start() async throws

    /// 停止采集并释放资源（定时器、observer、通知订阅）。重复调用应当是幂等的。
    func stop() async

    /// 运行时更新配置。
    ///
    /// 上一版的配置是 struct，启动时被各模块拷贝成自己的 `let`，
    /// 启动后改配置对已运行的模块完全无效——而另一些模块又实时读单例的 `var`，
    /// 两套语义混在一起，还顺带制造了一处跨线程数据竞争。
    func apply(_ options: Options) async
}

extension PerfMonitor {
    /// 默认不支持热更新。需要的监测器自行覆写。
    public func apply(_ options: Options) async {}

    public nonisolated var id: PerfMonitorID { Self.descriptor.id }
}

// MARK: - 类型擦除

/// 抹掉 `Options` 关联类型，使异构监测器能被统一编排。
public struct PerfAnyMonitor: Sendable {
    public let descriptor: PerfMonitorDescriptor

    private let _start: @Sendable () async throws -> Void
    private let _stop: @Sendable () async -> Void

    public init<M: PerfMonitor>(_ monitor: M) {
        self.descriptor = M.descriptor
        self._start = { try await monitor.start() }
        self._stop = { await monitor.stop() }
    }

    public func start() async throws {
        try await _start()
    }

    public func stop() async {
        await _stop()
    }
}

/// 一条「某监测器 + 它的配置」的注册信息。
///
/// 把构造延迟到 bootstrap 阶段，因为监测器需要 `PerfMonitorContext`，
/// 而 context 里的 session、sink 要等到框架启动时才存在。
public struct PerfMonitorRegistration: Sendable {
    public let descriptor: PerfMonitorDescriptor
    private let factory: @Sendable (PerfMonitorContext) -> PerfAnyMonitor

    public init<M: PerfMonitor>(type: M.Type, options: M.Options) {
        self.descriptor = M.descriptor
        self.factory = { context in
            PerfAnyMonitor(M(options: options, context: context))
        }
    }

    public func makeMonitor(context: PerfMonitorContext) -> PerfAnyMonitor {
        factory(context)
    }
}
