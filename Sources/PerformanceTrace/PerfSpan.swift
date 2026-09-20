import Foundation
import PerformanceCore
import os

/// Span 的分类。
public enum PerfSpanCategory: String, Codable, Sendable, CaseIterable {
    /// 通用业务链路。
    case span
    /// 页面加载。
    case page
    /// 布局 / 渲染阶段。
    case layout
}

/// 一次计时的结果。
public struct PerfSpanSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "trace.span"

    public let name: String
    public let category: PerfSpanCategory
    public let durationMs: Double
    /// 父 span 的名字。顶层 span 为 nil。
    public let parentName: String?
    /// 嵌套深度，顶层为 0。
    public let depth: Int

    /// 业务方附加的自定义数据。
    ///
    /// 这里用字符串字典是**刻意**的，与框架自身字段的处理方式不同：
    /// 框架的字段（耗时、深度、分类）都是强类型的，因为它们的语义是框架定义的；
    /// 而这些是业务方的开放数据，框架无从知道它的结构。
    ///
    /// 区别在于上一版把**框架自己的**指标也塞进了这种字典
    /// （fps、cpu_percent、ttfb_ms 全都字符串化），于是编译器彻底失去了约束力，
    /// 写入方写 `"cpu_percent"`、读取方读 `"cpuUsage"` 这种错误只能靠运行时发现。
    public let attributes: [String: String]?

    /// span 是否未正常结束（提前被丢弃或超时）。
    public let wasAbandoned: Bool

    public init(
        name: String,
        category: PerfSpanCategory,
        durationMs: Double,
        parentName: String?,
        depth: Int,
        attributes: [String: String]?,
        wasAbandoned: Bool = false
    ) {
        self.name = name
        self.category = category
        self.durationMs = durationMs
        self.parentName = parentName
        self.depth = depth
        self.attributes = attributes
        self.wasAbandoned = wasAbandoned
    }
}

/// 一个进行中的 span。
///
/// 值类型且不可变：拿着它不会意外改变任何状态，
/// 也就不会出现「同一个 token 被 end 两次」导致的重复计时。
public struct PerfSpanToken: Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let category: PerfSpanCategory
    public let startUptimeNanos: UInt64
    public let startDate: Date
    public let parentName: String?
    public let depth: Int

    init(
        id: UUID = UUID(),
        name: String,
        category: PerfSpanCategory,
        startUptimeNanos: UInt64,
        startDate: Date,
        parentName: String?,
        depth: Int
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.startUptimeNanos = startUptimeNanos
        self.startDate = startDate
        self.parentName = parentName
        self.depth = depth
    }
}

/// 打点的执行者。
///
/// 上一版把这件事做成了四套互不相干的 API——`PMMonitor.traceBegin/End`、
/// `PMIOTracker`、`PMLayoutRenderTracker`、`PMBusinessTracker`，
/// 每一套都自己写了一遍 `Double(end - start) / 1_000_000.0`，
/// 而 `PMMonitor` 内部的 `traceEnd`/`recordEvent`/`measure` 三个方法体
/// 又是逐行相同的复制粘贴。这里只有一处实现。
public struct PerfTracer: Sendable {
    let recorder: PerfRecorder
    let clock: any PerfClock
    let slowThreshold: PerfDuration
    let verySlowThreshold: PerfDuration
    let emitsSignposts: Bool

    private static let signposter = OSSignposter(
        subsystem: PerfLog.subsystem,
        category: "trace"
    )

    init(
        recorder: PerfRecorder,
        clock: any PerfClock,
        slowThreshold: PerfDuration,
        verySlowThreshold: PerfDuration,
        emitsSignposts: Bool
    ) {
        self.recorder = recorder
        self.clock = clock
        self.slowThreshold = slowThreshold
        self.verySlowThreshold = verySlowThreshold
        self.emitsSignposts = emitsSignposts
    }

    // MARK: - 显式配对

    public func begin(
        _ name: String,
        category: PerfSpanCategory = .span,
        parent: PerfSpanToken? = nil
    ) -> PerfSpanToken {
        if emitsSignposts {
            // 同时发一份 signpost，Instruments 里能直接看到时间线。
            // 两条路径互不依赖：线上靠落盘数据，本地调试靠 Instruments。
            Self.signposter.emitEvent("begin", "\(name, privacy: .public)")
        }
        return PerfSpanToken(
            name: name,
            category: category,
            startUptimeNanos: clock.uptimeNanos,
            startDate: clock.now,
            parentName: parent?.name,
            depth: (parent?.depth ?? -1) + 1
        )
    }

    public func end(
        _ token: PerfSpanToken,
        attributes: [String: String]? = nil,
        abandoned: Bool = false
    ) {
        let now = clock.uptimeNanos
        let durationNanos = now > token.startUptimeNanos ? now - token.startUptimeNanos : 0

        if emitsSignposts {
            Self.signposter.emitEvent("end", "\(token.name, privacy: .public)")
        }

        recorder.record(
            PerfSpanSample(
                name: token.name,
                category: token.category,
                durationMs: Double(durationNanos) / 1_000_000,
                parentName: token.parentName,
                depth: token.depth,
                attributes: attributes,
                wasAbandoned: abandoned
            ),
            severity: severity(for: durationNanos, abandoned: abandoned),
            thread: .current(),
            // 时间戳取 span **开始**的时刻，不是结束的时刻。
            // 一个 5 秒的 span 若按结束时刻落盘，在时间线上会与
            // 同期的 CPU、内存采样完全错位。
            timestamp: token.startDate,
            uptimeNanos: token.startUptimeNanos
        )
    }

    // MARK: - 闭包形式

    /// 自动配对的同步计时。
    ///
    /// 与异步版本一样经 task-local 建立嵌套关系。两者必须行为一致：
    /// 一个**不含 await** 的闭包会被重载决议选到这个同步版本，
    /// 哪怕它写在 `await measure { ... }` 里面。若只有异步版支持嵌套，
    /// 「嵌套是否生效」就取决于内层闭包碰巧有没有 await，行为不可预期。
    public func measure<T>(
        _ name: String,
        category: PerfSpanCategory = .span,
        parent: PerfSpanToken? = nil,
        attributes: [String: String]? = nil,
        body: () throws -> T
    ) rethrows -> T {
        let token = begin(name, category: category, parent: parent ?? PerfTrace.currentSpan)
        do {
            let result = try PerfTrace.$currentSpan.withValue(token) {
                try body()
            }
            end(token, attributes: attributes)
            return result
        } catch {
            // 抛错路径也要结算，否则一旦业务代码出错，
            // 这条 span 就永远没有终点，数据里只剩一个悬空的开始
            end(token, attributes: attributes, abandoned: true)
            throw error
        }
    }

    /// 自动配对的异步计时。嵌套关系经 task-local 自动建立。
    public func measure<T>(
        _ name: String,
        category: PerfSpanCategory = .span,
        parent: PerfSpanToken? = nil,
        attributes: [String: String]? = nil,
        body: () async throws -> T
    ) async rethrows -> T {
        let token = begin(name, category: category, parent: parent ?? PerfTrace.currentSpan)
        do {
            let result = try await PerfTrace.$currentSpan.withValue(token) {
                try await body()
            }
            end(token, attributes: attributes)
            return result
        } catch {
            end(token, attributes: attributes, abandoned: true)
            throw error
        }
    }

    private func severity(for durationNanos: UInt64, abandoned: Bool) -> PerfSeverity {
        if abandoned { return .warning }
        if durationNanos >= verySlowThreshold.nanoseconds { return .error }
        if durationNanos >= slowThreshold.nanoseconds { return .warning }
        return .info
    }
}
