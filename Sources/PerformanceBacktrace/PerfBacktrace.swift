import Foundation
import CPerfBacktrace
import PerformanceCore

/// `PerfBacktraceProviding` 的实现：C 层回溯能力的 Swift 封装。
///
/// 阶段 3 实现。当前仅完成主线程端口登记——这一步必须在 bootstrap 时
/// 于主线程执行，越早越好。
public enum PerfBacktrace {
    /// 登记主线程端口。**必须在主线程调用**。
    ///
    /// 之后任何线程都能可靠地拿到主线程句柄去抓它的栈，
    /// 而不必依赖 `task_threads()` 那个顺序无保证的数组。
    public static func registerMainThread() {
        cperf_register_main_thread()
    }

    /// 主线程句柄。未登记时返回 nil。
    public static var mainThreadHandle: PerfThreadHandle? {
        let port = cperf_main_thread_port()
        return port == mach_port_t(MACH_PORT_NULL) ? nil : PerfThreadHandle(machPort: port)
    }
}
