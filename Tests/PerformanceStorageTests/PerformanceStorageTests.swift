import Testing

@testable import PerformanceStorage

/// 阶段 2 填充：分片滚动边界、配额触发删除、进程被 kill 后的截断行恢复、
/// 多线程并发写不交错、过期清理。
@Suite("PerfStorage")
struct PerformanceStorageTests {
    @Test("模块占位")
    func modulePlaceholder() {
        #expect(!PerfStorage.moduleVersion.isEmpty)
    }
}
