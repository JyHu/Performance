import Foundation
import PerformanceCore

/// 业务打点的全局入口。
///
/// ## 为什么这里需要一个进程级入口
///
/// 与 `PerfLaunchTimeline` 同理：打点是**业务代码在任意位置**发起的，
/// 不可能要求每个调用点都先拿到 `PerfMonitorContext`。
///
/// 但要注意这里存的只是一个 `PerfTracer` 值（它内部持有 recorder 和 clock），
/// 监测器停掉后会被置为 nil，此时所有打点调用退化为空操作。
/// 这与上一版那种「监测器自己是单例、还带副作用」的形态不同——
/// 那一版的 `PMANRReporter` 在 `private init()` 里就启动了 30 分钟定时器，
/// 首次访问 `.shared` 就产生副作用，而且没有任何 `stop()` 入口。
public enum PerfTrace {
    /// 当前 span，用于异步代码的自动嵌套。
    @TaskLocal
    public static var currentSpan: PerfSpanToken?

    private static let storage = TracerStorage()

        /// 当前可用的 tracer。监测器未启动时为 nil。
    public static var tracer: PerfTracer? {
        storage.tracer
    }

    static func install(_ tracer: PerfTracer?) {
        storage.tracer = tracer
    }

    // MARK: - 命名空间常量

    public static let monitorID: PerfMonitorID = "trace"

    /// 本监测器产出的记录类型。
    public enum Kinds {
        public static let span: PerfKind = "trace.span"
        public static let page: PerfKind = "trace.page"
        public static let layout: PerfKind = "trace.layout"
    }

    // MARK: - 便捷入口
    //
    // 监测器未启动时全部退化为空操作，业务方无需判空。

    public static func begin(
        _ name: String,
        category: PerfSpanCategory = .span,
        parent: PerfSpanToken? = nil
    ) -> PerfSpanToken? {
        tracer?.begin(name, category: category, parent: parent)
    }

    public static func end(
        _ token: PerfSpanToken?,
        attributes: [String: String]? = nil
    ) {
        guard let token else { return }
        tracer?.end(token, attributes: attributes)
    }

    /// 同步计时。未启用监测时直接执行 body，不产生任何开销。
    public static func measure<T>(
        _ name: String,
        category: PerfSpanCategory = .span,
        attributes: [String: String]? = nil,
        body: () throws -> T
    ) rethrows -> T {
        guard let tracer else { return try body() }
        return try tracer.measure(name, category: category, attributes: attributes, body: body)
    }

    /// 异步计时，自动建立嵌套关系。
    public static func measure<T>(
        _ name: String,
        category: PerfSpanCategory = .span,
        attributes: [String: String]? = nil,
        body: () async throws -> T
    ) async rethrows -> T {
        guard let tracer else { return try await body() }
        return try await tracer.measure(name, category: category, attributes: attributes, body: body)
    }

    /// 页面加载计时。
    public static func measurePage<T>(_ name: String, body: () throws -> T) rethrows -> T {
        try measure(name, category: .page, body: body)
    }

    /// 布局 / 渲染阶段计时。
    public static func measureLayout<T>(_ name: String, body: () throws -> T) rethrows -> T {
        try measure(name, category: .layout, body: body)
    }

    private final class TracerStorage: @unchecked Sendable {
        private let lock = PerfLock()
        private var storage: PerfTracer?

        var tracer: PerfTracer? {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }
}

// MARK: - 监测器

public struct PerfTraceMonitorOptions: PerfMonitorOptions {
    /// 超过此耗时的 span 定级为 warning。
    public var slowThreshold: PerfDuration = .milliseconds(500)
    /// 超过此耗时的 span 定级为 error。
    public var verySlowThreshold: PerfDuration = .seconds(2)
    /// 是否同时发出 `os_signpost`，供 Instruments 查看。
    public var emitsSignposts: Bool = true

    public init() {}
}

/// 自定义打点监测。
///
/// 它本身不主动采集任何数据——数据来自业务代码的打点调用。
/// 这个监测器的职责只是「把 tracer 接上，停止时拔掉」。
public actor PerfTraceMonitor: PerfMonitor {
    public nonisolated static let descriptor = PerfMonitorDescriptor(
        id: PerfTrace.monitorID,
        displayName: "自定义打点",
        kinds: [PerfSpanSample.kind],
        platforms: .all
    )

    private var options: PerfTraceMonitorOptions
    private let context: PerfMonitorContext

    public init(options: PerfTraceMonitorOptions, context: PerfMonitorContext) {
        self.options = options
        self.context = context.scoped(to: Self.descriptor.id)
    }

    public func start() async throws {
        PerfTrace.install(makeTracer())
    }

    public func stop() async {
        // 拔掉之后，业务代码里的打点调用全部退化为空操作。
        // 不留任何后台活动——这正是上一版做不到的：
        // 它的 ANR 上报器在首次访问单例时就起了定时器，且没有停止入口。
        PerfTrace.install(nil)
    }

    public func apply(_ options: PerfTraceMonitorOptions) async {
        self.options = options
        PerfTrace.install(makeTracer())
    }

    private func makeTracer() -> PerfTracer {
        PerfTracer(
            recorder: context.recorder,
            clock: context.clock,
            slowThreshold: options.slowThreshold,
            verySlowThreshold: options.verySlowThreshold,
            emitsSignposts: options.emitsSignposts
        )
    }
}
