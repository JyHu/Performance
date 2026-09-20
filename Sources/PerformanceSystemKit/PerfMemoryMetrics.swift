import Darwin
import Foundation
import PerformanceCore

/// 进程与系统的内存指标。
public struct PerfMemoryMetrics: Sendable, Hashable {
    /// 物理内存足迹。
    ///
    /// **这是判断 OOM 风险的正确指标**：iOS 的 jetsam 正是按这个值决定杀谁。
    /// 它计入进程实际「拥有」的物理页，已扣除与系统共享的部分。
    public let footprintBytes: UInt64

    /// 常驻内存。
    ///
    /// 包含与其他进程共享的页（framework 的只读段等），因此**高于**足迹。
    /// 上一版用它当「内存占用」上报，会系统性高估，
    /// 且与另一处用 `phys_footprint` 的代码对不上——同一时刻两个数。
    public let residentBytes: UInt64

    /// 已提交的虚拟内存。
    public let virtualBytes: UInt64

    /// 进程可用内存上限的剩余量。取不到时为 nil。
    public let availableToProcessBytes: UInt64?

    /// 系统级可用物理内存（free + inactive + speculative）。
    public let systemAvailableBytes: UInt64?

    /// 设备物理内存总量。
    public let systemTotalBytes: UInt64

    public var footprintMegabytes: Double {
        Double(footprintBytes) / 1_048_576
    }
}

extension PerfMemoryMetrics {
    /// 采集当前内存指标。
    public static func current() -> PerfMemoryMetrics {
        let vmInfo = taskVMInfo()
        return PerfMemoryMetrics(
            footprintBytes: vmInfo?.phys_footprint ?? 0,
            residentBytes: vmInfo?.resident_size ?? 0,
            virtualBytes: vmInfo?.virtual_size ?? 0,
            availableToProcessBytes: availableToProcess(vmInfo: vmInfo),
            systemAvailableBytes: systemAvailable(),
            systemTotalBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    /// `task_info(TASK_VM_INFO)`。
    ///
    /// 必须按实际返回的 count 判断 `phys_footprint` 是否有效——
    /// 这个字段是后加的，老系统上结构体更短，直接读会拿到未初始化的内存。
    static func taskVMInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    private static func availableToProcess(vmInfo: task_vm_info_data_t?) -> UInt64? {
        guard let vmInfo else { return nil }
        let limit = vmInfo.limit_bytes_remaining
        // 未设限时内核返回一个哨兵大值，直接上报会让「剩余内存」看起来是天文数字
        guard limit > 0, limit < UInt64.max / 2 else { return nil }
        return limit
    }

    /// 系统级可用内存。
    ///
    /// 只算 free 是不对的：inactive 和 speculative 页在压力下可以被回收，
    /// 对「还能再分配多少」而言它们同样是可用的。
    private static func systemAvailable() -> UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let reclaimable = UInt64(stats.free_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count)
        return reclaimable * kernelPageSize
    }

    /// 内核页大小。
    ///
    /// 不读全局变量 `vm_kernel_page_size`——它是可变全局量，在严格并发下不可用；
    /// 而且这个值与 `_SC_PAGESIZE` 在某些配置下并不相同，
    /// `vm_statistics64` 的计数必须乘以**内核**页大小才对。
    private static let kernelPageSize: UInt64 = {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 else {
            return 4_096
        }
        return UInt64(size)
    }()
}
