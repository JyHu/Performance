import Foundation

/// 监测器记录数据的便捷入口。
///
/// 把 sink、session、clock 绑在一起，让采集器写一行就能出一条完整记录，
/// 而不必每次自己拼时间戳和 session——那正是上一版里
/// 「六行 diagnose → capture → PMEvent → append 样板被复制三份」的成因。
public struct PerfRecorder: Sendable {
    public let sink: any PerfEventSink
    public let sessionID: PerfSessionID
    public let clock: any PerfClock

    public init(sink: any PerfEventSink, sessionID: PerfSessionID, clock: any PerfClock) {
        self.sink = sink
        self.sessionID = sessionID
        self.clock = clock
    }

    /// 记录一条数据。
    ///
    /// - Parameters:
    ///   - payload: 类型安全的载荷。
    ///   - severity: 严重度。默认 `.info`，即常规采样。
    ///   - thread: 被观测的线程。注意应传**被观测**的线程而非采集线程——
    ///     例如在后台线程上抓到主线程卡顿时，这里要填 `.main`。
    public func record<P: PerfPayload>(
        _ payload: P,
        severity: PerfSeverity = .info,
        thread: PerfThreadRef? = nil
    ) {
        let record = PerfAnyRecord(
            timestamp: clock.now,
            uptimeNanos: clock.uptimeNanos,
            sessionID: sessionID,
            severity: severity,
            thread: thread,
            kind: P.kind,
            schemaVersion: P.schemaVersion,
            payload: payload
        )
        sink.submit(record)
    }

    /// 记录一条数据，并显式指定时间。
    ///
    /// 用于「事件发生在过去、现在才处理完」的场景：例如卡顿是在 T0 开始的，
    /// 但堆栈要到 T0+3s 才抓完。此时应以 T0 为准，否则时间线会错位。
    public func record<P: PerfPayload>(
        _ payload: P,
        severity: PerfSeverity = .info,
        thread: PerfThreadRef? = nil,
        timestamp: Date,
        uptimeNanos: UInt64
    ) {
        let record = PerfAnyRecord(
            timestamp: timestamp,
            uptimeNanos: uptimeNanos,
            sessionID: sessionID,
            severity: severity,
            thread: thread,
            kind: P.kind,
            schemaVersion: P.schemaVersion,
            payload: payload
        )
        sink.submit(record)
    }
}
