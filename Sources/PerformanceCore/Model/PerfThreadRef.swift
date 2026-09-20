import Foundation

/// 记录产生于哪个线程。
///
/// 区分主线程与后台线程是性能排查的基本维度——同样 50ms 的耗时，
/// 在主线程上是卡顿，在后台线程上通常无害。
public struct PerfThreadRef: Hashable, Sendable, Codable {
    public let isMain: Bool
    /// mach 线程端口，用于和栈回溯结果关联。
    public let machPort: UInt32?
    public let name: String?

    public init(isMain: Bool, machPort: UInt32? = nil, name: String? = nil) {
        self.isMain = isMain
        self.machPort = machPort
        self.name = name
    }

    /// 当前线程的引用。
    ///
    /// 用 `pthread_mach_thread_np(pthread_self())` 而不是 `mach_thread_self()`：
    /// 后者返回一个需要 `mach_port_deallocate` 释放的 send right，
    /// 在高频采集路径上忘记释放会导致端口泄漏。
    public static func current() -> PerfThreadRef {
        let isMain = Thread.isMainThread
        let port = pthread_mach_thread_np(pthread_self())
        let name = Thread.current.name
        return PerfThreadRef(
            isMain: isMain,
            machPort: port,
            name: (name?.isEmpty == false) ? name : nil
        )
    }

    /// 主线程的引用（不查询端口，供不在主线程上构造时使用）。
    public static let main = PerfThreadRef(isMain: true, machPort: nil, name: "main")
}

extension PerfThreadRef: CustomStringConvertible {
    public var description: String {
        if isMain { return "main" }
        if let name { return name }
        if let machPort { return "thread-\(machPort)" }
        return "background"
    }
}
