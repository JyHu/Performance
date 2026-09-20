import Foundation
import PerformanceCore
import PerformanceSystemKit

/// 启动过程中各关键时刻的记录板。
///
/// ## 为什么这里有一个进程级单例
///
/// 框架整体是反对单例的——依赖一律经 `PerfMonitorContext` 注入，
/// 这样每个监测器都能被测试。但启动计时是一个真实的例外：
///
/// 要记录的事件（进程创建、`main()` 进入、首帧渲染）中，有些发生在
/// 框架被配置**之前**。如果非要等监测器构造好才开始记，
/// 就永远拿不到启动最前面那一段——而那一段恰恰是最值得优化的部分。
///
/// 所以这里放一个**只记时间戳、没有任何行为**的记录板，
/// 业务方可以在 `main()` 的第一行就往里打点，监测器起来之后再来读。
public final class PerfLaunchTimeline: @unchecked Sendable {
    public static let shared = PerfLaunchTimeline()

    private let lock = PerfLock()
    private var marks: [String: UInt64] = [:]
    private var marksWallClock: [String: Date] = [:]

    /// 进程创建时刻，来自内核。
    ///
    /// 这是冷启动的**真正**起点。上一版用 `ProcessInfo.systemUptime` 当起点，
    /// 那是设备开机至今的时长，与本次进程何时启动毫无关系——
    /// 算出来的「冷启动耗时」实际上是设备已运行的时间。
    public let processStartDate: Date?

    /// 本类型被首次访问的时刻。
    ///
    /// 框架越晚初始化，这个值离进程创建就越远，
    /// 中间那段时间的信息就是缺失的。它被如实上报，
    /// 好让分析时知道「启动耗时里有多少是没被观测到的」。
    public let frameworkLoadUptime: UInt64
    public let frameworkLoadDate: Date

    private init() {
        processStartDate = PerfProcessMetrics.processStartDate()
        frameworkLoadUptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        frameworkLoadDate = Date()
    }

    /// 标记一个启动阶段的时刻。
    ///
    /// 可以在任意线程、任意时刻调用，包括框架尚未配置时。
    public func mark(_ name: String, at date: Date = Date()) {
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        lock.withLock {
            // 只保留首次：启动阶段按定义只发生一次，
            // 重复打点（例如热启动时又走了一遍）不该覆盖冷启动的数据
            guard marks[name] == nil else { return }
            marks[name] = uptime
            marksWallClock[name] = date
        }
    }

    /// 读取某个标记的单调时间戳。
    public func uptime(of name: String) -> UInt64? {
        lock.withLock { marks[name] }
    }

    public func date(of name: String) -> Date? {
        lock.withLock { marksWallClock[name] }
    }

    /// 全部标记，按时间排序。
    public func allMarks() -> [(name: String, uptime: UInt64)] {
        lock.withLock {
            marks.map { (name: $0.key, uptime: $0.value) }
                .sorted { $0.uptime < $1.uptime }
        }
    }

    /// 清空标记。仅供测试使用。
    public func reset() {
        lock.withLock {
            marks.removeAll()
            marksWallClock.removeAll()
        }
    }

    // MARK: - 约定的标记名

    public enum Mark {
        /// `main()` 入口。业务方应在 main 的第一行调用。
        public static let main = "main"
        /// 首帧渲染完成。
        ///
        /// 框架自己会用「首次主 RunLoop 空闲」做近似，
        /// 但那只是代理指标。业务方若在真正的首屏出现处调用
        /// `PerfLaunchTimeline.shared.mark(.firstFrame)`，数据会准确得多。
        public static let firstFrame = "first_frame"
        /// 首屏可交互。
        public static let interactive = "interactive"
    }
}

extension PerfLaunchTimeline {
    /// 标记首帧。便捷入口。
    public static func markFirstFrame() {
        shared.mark(Mark.firstFrame)
    }

    /// 标记首屏可交互。
    public static func markInteractive() {
        shared.mark(Mark.interactive)
    }
}
