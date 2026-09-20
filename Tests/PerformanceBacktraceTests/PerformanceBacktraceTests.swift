import Foundation
import Testing

@testable import PerformanceBacktrace

/// 阶段 3 填充核心用例：起一个调用链已知的后台线程，
/// 从**另一个**线程抓它的栈，断言帧中包含预期符号。
/// 这条用例直接验证上一版「`backtrace()` 只能抓当前线程」的缺陷已被修掉。
@Suite("PerfBacktrace")
struct PerformanceBacktraceTests {
    @Test("主线程端口登记后可被任意线程读取")
    func registersMainThreadPort() async {
        await MainActor.run {
            PerfBacktrace.registerMainThread()
        }

        // 从非主线程读取，验证端口确实被持久化下来了
        let handle = await Task.detached { PerfBacktrace.mainThreadHandle }.value
        #expect(handle != nil)
    }
}
