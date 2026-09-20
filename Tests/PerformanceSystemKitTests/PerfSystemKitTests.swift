import Foundation
import Testing

import PerformanceCore
@testable import PerformanceSystemKit

@Suite("内存指标")
struct PerfMemoryMetricsTests {
    @Test("足迹与常驻内存都能取到且数值合理")
    func readsMemoryMetrics() {
        let metrics = PerfMemoryMetrics.current()

        #expect(metrics.footprintBytes > 0)
        #expect(metrics.residentBytes > 0)
        #expect(metrics.systemTotalBytes > 0)
        // 单个进程的足迹不该超过设备物理内存总量
        #expect(metrics.footprintBytes < metrics.systemTotalBytes)
    }

    @Test("足迹不超过常驻内存")
    func footprintDoesNotExceedResident() {
        let metrics = PerfMemoryMetrics.current()
        // 常驻内存含与系统共享的页（framework 只读段等），因此总是 ≥ 足迹。
        // 上一版一处用 resident、另一处用 footprint，同一时刻给出两个不同的
        // 「内存占用」，报表之间永远对不上。
        #expect(metrics.footprintBytes <= metrics.residentBytes)
    }

    @Test("分配大块内存后足迹上升")
    func footprintReflectsAllocation() {
        let before = PerfMemoryMetrics.current().footprintBytes

        // 逐字节写入，强制内核真正分配物理页——只 malloc 不写不会体现在足迹里
        var blob = [UInt8](repeating: 0, count: 32 * 1_024 * 1_024)
        for index in stride(from: 0, to: blob.count, by: 4_096) {
            blob[index] = 1
        }

        let after = PerfMemoryMetrics.current().footprintBytes
        #expect(after > before)

        withExtendedLifetime(blob) {}
    }

    @Test("系统可用内存取得到且不超过总量")
    func readsSystemAvailableMemory() throws {
        let metrics = PerfMemoryMetrics.current()
        let available = try #require(metrics.systemAvailableBytes)
        #expect(available > 0)
        #expect(available <= metrics.systemTotalBytes)
    }
}

@Suite("CPU 指标")
struct PerfCPUMetricsTests {
    @Test("累计 CPU 时间可读且单调递增")
    func readsCumulativeCPUTime() throws {
        let first = try #require(PerfCPUMetrics.processCPUTime())
        #expect(first.totalNanos > 0)

        // 空转一小会儿制造 CPU 时间
        var accumulator: UInt64 = 0
        for index in 0..<2_000_000 { accumulator = accumulator &+ UInt64(index) }
        withExtendedLifetime(accumulator) {}

        let second = try #require(PerfCPUMetrics.processCPUTime())
        #expect(second.totalNanos >= first.totalNanos)
    }

    @Test("占用率按时间窗口计算")
    func computesUsagePercent() {
        let start = PerfCPUTime(userNanos: 0, systemNanos: 0)
        // 1 秒窗口里用掉 500ms CPU = 50%
        let end = PerfCPUTime(userNanos: 400_000_000, systemNanos: 100_000_000)

        #expect(end.usagePercent(since: start, elapsed: .seconds(1)) == 50)
        // 多核满载时可以超过 100%，不该被夹住
        #expect(end.usagePercent(since: start, elapsed: .milliseconds(250)) == 200)
    }

    @Test("时间窗口为零时返回 0 而不是除零")
    func handlesZeroElapsed() {
        let time = PerfCPUTime(userNanos: 100, systemNanos: 100)
        #expect(time.usagePercent(since: PerfCPUTime(userNanos: 0, systemNanos: 0), elapsed: .zero) == 0)
    }

    @Test("累计值回退时按 0 处理，不产生负占用率")
    func clampsNegativeDelta() {
        let later = PerfCPUTime(userNanos: 100, systemNanos: 0)
        let earlier = PerfCPUTime(userNanos: 500, systemNanos: 0)
        #expect(later.usagePercent(since: earlier, elapsed: .seconds(1)) == 0)
    }

    @Test("能枚举线程并标出主线程")
    func enumeratesThreads() async {
        await MainActor.run { PerfSystemKit.registerMainThread() }

        let threads = PerfCPUMetrics.threadCPU(includeIdle: true)
        #expect(!threads.isEmpty)
        #expect(threads.contains { $0.isMain })
        #expect(threads.allSatisfy { $0.machPort != 0 })
    }

    @Test("默认排除空闲线程")
    func excludesIdleThreadsByDefault() {
        let all = PerfCPUMetrics.threadCPU(includeIdle: true)
        let busy = PerfCPUMetrics.threadCPU(includeIdle: false)

        // 一个 app 常有几十个空闲的 GCD 工作线程，它们会淹没真正的热点线程
        #expect(busy.count <= all.count)
        #expect(busy.allSatisfy { !$0.isIdle })
    }

    @Test("线程数为正，且与枚举结果一致")
    func countsThreads() {
        let count = PerfCPUMetrics.threadCount()
        #expect(count > 0)
        #expect(count >= PerfCPUMetrics.threadCPU(includeIdle: true).count)
    }

    @Test("反复枚举线程不泄漏 mach 端口")
    func doesNotLeakThreadPorts() {
        // 每次 task_threads 都会为每个线程返回一个 send right。
        // 忘记逐个 deallocate 的话，端口数会随采样次数线性增长，
        // 最终耗尽进程的端口表——这类泄漏在测试里只能靠反复调用暴露。
        let baseline = PerfCPUMetrics.threadCount()
        for _ in 0..<300 {
            _ = PerfCPUMetrics.threadCPU(includeIdle: true)
        }
        let after = PerfCPUMetrics.threadCount()
        #expect(abs(after - baseline) < 20)
    }
}

@Suite("磁盘指标")
struct PerfDiskMetricsTests {
    @Test("磁盘 I/O 的可用性符合平台事实")
    func diskIOAvailabilityMatchesPlatform() throws {
        #if os(macOS)
        let io = try #require(PerfDiskMetrics.processIO())
        #expect(io.bytesRead > 0 || io.bytesWritten > 0)
        #else
        // iOS 没有公开 API 能拿到进程磁盘 I/O 字节数（唯一来源 proc_pid_rusage
        // 在 iOS SDK 里没有声明）。这里必须返回 nil 而不是 0——
        // 返回 0 会被误读成「完全没有磁盘活动」。
        #expect(PerfDiskMetrics.processIO() == nil)
        #endif
    }

    @Test("吞吐按时间窗口计算")
    func computesThroughput() {
        let start = PerfDiskIO(bytesRead: 0, bytesWritten: 0)
        let end = PerfDiskIO(bytesRead: 2_048, bytesWritten: 1_024)

        let throughput = end.throughput(since: start, elapsed: .seconds(2))
        #expect(throughput.read == 1_024)
        #expect(throughput.written == 512)
    }

    @Test("卷容量合理")
    func readsVolumeCapacity() throws {
        let capacity = try #require(PerfDiskMetrics.volumeCapacity())
        #expect(capacity.totalBytes > 0)

        if let available = capacity.availableBytes {
            #expect(available <= capacity.totalBytes)
        }
    }
}

@Suite("进程指标")
struct PerfProcessMetricsTests {
    @Test("进程创建时间是过去的时刻")
    func readsProcessStartDate() throws {
        let start = try #require(PerfProcessMetrics.processStartDate())
        #expect(start < Date())
        // 测试进程不该「启动于」一天以前
        #expect(Date().timeIntervalSince(start) < 86_400)
    }

    @Test("已运行时长为正，且与创建时间一致")
    func computesUptime() throws {
        let uptime = try #require(PerfProcessMetrics.uptime())
        #expect(uptime.nanoseconds > 0)

        let start = try #require(PerfProcessMetrics.processStartDate())
        let expected = Date().timeIntervalSince(start)
        #expect(abs(uptime.seconds - expected) < 1)
    }

    @Test("进程创建时间与设备开机时长是两回事")
    func startDateIsNotSystemUptime() throws {
        let uptime = try #require(PerfProcessMetrics.uptime())
        let systemUptime = ProcessInfo.processInfo.systemUptime

        // 上一版用 systemUptime 当启动起点，算出来的「冷启动耗时」
        // 实际是设备开机至今的时长。这里断言两者确实不同，
        // 除非设备恰好刚开机就跑了测试（差值小于 2 秒才可能混淆）。
        if systemUptime > 60 {
            #expect(abs(uptime.seconds - systemUptime) > 1)
        }
    }

    @Test("调试器检测不崩溃")
    func detectsDebugger() {
        // 结果取决于是否挂了调试器，这里只验证调用安全
        _ = PerfProcessMetrics.isDebuggerAttached()
        #expect(Bool(true))
    }
}
