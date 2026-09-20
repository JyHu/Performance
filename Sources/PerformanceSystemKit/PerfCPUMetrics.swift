import CPerfBacktrace
import CPerfSystem
import Darwin
import Foundation
import PerformanceCore

/// 进程累计 CPU 时间。
///
/// 上报的是**累计值**而非百分比，由调用方按采样间隔做差分。
/// 百分比必须相对某个时间窗口才有意义，让采集层直接吐百分比会丢掉这个窗口信息，
/// 不同采样周期的数据也就没法互相比较了。
public struct PerfCPUTime: Sendable, Hashable {
    public let userNanos: UInt64
    public let systemNanos: UInt64

    public var totalNanos: UInt64 { userNanos &+ systemNanos }

    public init(userNanos: UInt64, systemNanos: UInt64) {
        self.userNanos = userNanos
        self.systemNanos = systemNanos
    }

    /// 相对上一次采样的 CPU 占用率。
    ///
    /// - Parameter elapsed: 两次采样之间的**墙上**时长。
    /// - Returns: 百分比。多核满载时可以超过 100。
    public func usagePercent(since previous: PerfCPUTime, elapsed: PerfDuration) -> Double {
        guard elapsed.nanoseconds > 0 else { return 0 }
        let delta = totalNanos > previous.totalNanos ? totalNanos - previous.totalNanos : 0
        return Double(delta) / Double(elapsed.nanoseconds) * 100
    }
}

/// 单个线程的 CPU 状况。
public struct PerfThreadCPU: Sendable, Hashable {
    public let machPort: UInt32
    public let name: String?
    public let isMain: Bool
    /// 瞬时 CPU 占用百分比（0~100）。
    public let usagePercent: Double
    public let userNanos: UInt64
    public let systemNanos: UInt64
    /// 线程是否处于空闲等待状态。
    public let isIdle: Bool
}

/// 进程级 CPU 与线程指标。
public enum PerfCPUMetrics {
    /// 进程累计 CPU 时间。
    ///
    /// 用 `proc_pid_rusage` 而不是 `task_info(TASK_BASIC_INFO)`：
    /// 后者的 `user_time`/`system_time` 只累计**已终止**线程的时间，
    /// 要拿到进程总量还得再遍历所有活动线程逐个相加。
    /// 上一版就是这么做的，既慢又容易在线程增删的瞬间算漏。
    public static func processCPUTime() -> PerfCPUTime? {
        guard let usage = resourceUsage(), usage.has_cpu_time else { return nil }
        return PerfCPUTime(userNanos: usage.user_time_nanos, systemNanos: usage.system_time_nanos)
    }

    /// 全部线程的 CPU 状况。
    ///
    /// - Parameter includeIdle: 是否包含空闲线程。默认排除——
    ///   一个 app 常有几十个空闲的 GCD 工作线程，它们淹没真正的热点线程。
    public static func threadCPU(includeIdle: Bool = false) -> [PerfThreadCPU] {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0

        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
              let threads
        else { return [] }

        defer {
            for index in 0..<Int(count) {
                mach_port_deallocate(mach_task_self_, threads[index])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            )
        }

        var result: [PerfThreadCPU] = []
        result.reserveCapacity(Int(count))

        for index in 0..<Int(count) {
            let port = threads[index]
            guard let info = basicInfo(for: port) else { continue }

            let isIdle = (info.flags & TH_FLAGS_IDLE) != 0
            guard includeIdle || !isIdle else { continue }

            result.append(
                PerfThreadCPU(
                    machPort: port,
                    name: threadName(for: port),
                    isMain: port == mainThreadPort,
                    // cpu_usage 的单位是 TH_USAGE_SCALE（1000），不是百分比
                    usagePercent: Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100,
                    userNanos: nanoseconds(from: info.user_time),
                    systemNanos: nanoseconds(from: info.system_time),
                    isIdle: isIdle
                )
            )
        }
        return result
    }

    /// 线程总数（含空闲线程）。
    ///
    /// 线程数异常增长是线程池失控或死锁的早期信号，
    /// 往往比 CPU 和内存更早暴露问题。
    public static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
              let threads
        else { return 0 }

        for index in 0..<Int(count) {
            mach_port_deallocate(mach_task_self_, threads[index])
        }
        vm_deallocate(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: threads)),
            vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
        )
        return Int(count)
    }

    // MARK: - 内部

    /// 主线程端口，取自 C 层那一份唯一登记。
    ///
    /// 不在这里自己再存一份：两处登记意味着两处都可能忘记调用，
    /// 而症状是「主线程标记静默失效」——没有报错，只是数据悄悄变错。
    private static var mainThreadPort: mach_port_t {
        cperf_main_thread_port()
    }

    /// 进程资源使用量。
    ///
    /// 走 `CPerfSystem` 垫片：其中几项指标在两个平台上的可用性不同，
    /// 差异被收敛在那一层，Swift 侧只看 `has_*` 标志。
    static func resourceUsage() -> cperf_rusage_t? {
        var usage = cperf_rusage_t()
        return cperf_process_rusage(&usage) ? usage : nil
    }

    /// `THREAD_BASIC_INFO_COUNT` 宏在 Swift 里不可见，按结构体尺寸算。
    private static let threadBasicInfoCount = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size
    )

    private static func basicInfo(for thread: thread_t) -> thread_basic_info? {
        var info = thread_basic_info()
        var count = threadBasicInfoCount

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    private static func threadName(for thread: thread_t) -> String? {
        guard let handle = pthread_from_mach_thread_np(thread) else { return nil }
        var buffer = [CChar](repeating: 0, count: 64)
        guard pthread_getname_np(handle, &buffer, buffer.count) == 0 else { return nil }

        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    private static func nanoseconds(from value: time_value_t) -> UInt64 {
        UInt64(value.seconds) &* 1_000_000_000 &+ UInt64(value.microseconds) &* 1_000
    }
}
