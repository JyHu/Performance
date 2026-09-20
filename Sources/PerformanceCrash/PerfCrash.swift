import Foundation
import CPerfCrash
import PerformanceCore
import PerformanceBacktrace

/// 崩溃捕获。阶段 5 实现。
///
/// 上一版只装了 `NSSetUncaughtExceptionHandler`，
/// 也就是说只能捕获 Objective-C 异常——而 iOS 上绝大多数崩溃是
/// `SIGSEGV`（野指针）、`SIGABRT`（断言/未捕获的 Swift 错误）、
/// `EXC_BAD_ACCESS`，这些全都拦不到。
public enum PerfCrash {
    public static let monitorID: PerfMonitorID = "crash"

    public enum Kinds {
        public static let signal: PerfKind = "crash.signal"
        public static let machException: PerfKind = "crash.mach_exception"
        public static let uncaughtException: PerfKind = "crash.uncaught_exception"
    }
}
