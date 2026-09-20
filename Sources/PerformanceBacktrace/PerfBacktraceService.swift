import CPerfBacktrace
import Foundation
import PerformanceCore

/// `PerfBacktraceProviding` 的生产实现。
///
/// ## 这一层存在的理由
///
/// 上一版的 `PMStackHelper.captureMainThreadStack()` 用的是 C 的 `backtrace()`，
/// 而该 API **只能抓当前调用线程**的栈。它的四个调用方全都在后台队列上：
/// `PMSystemMetricsMonitor`（systemmetrics 队列）、`PMNetworkMonitor`（URLSession 队列）、
/// `PMMainThreadDeadlockDetector`（watchdog 队列）、`PMANRDetactor`（watchdog 队列）。
///
/// 于是所有标着「主线程堆栈」的数据，实际上都是采集线程自己的栈。
/// 采集到的不是问题现场，而是采集代码自己——对排查毫无价值，
/// 却又长得像真数据，反而会把排查引向错误方向。
public struct PerfBacktraceService: PerfBacktraceProviding {
    /// 单次符号化的最大帧数。超出部分只保留地址。
    ///
    /// 限制的理由是 `dladdr` 会拿 dyld 的锁：在卡顿现场对 128 帧逐个符号化，
    /// 采集本身就可能变成新的阻塞点。默认只符号化栈顶部分——
    /// 定位问题靠的也主要是栈顶。
    public let maxSymbolicatedFrames: Int

    /// 是否在采集时就做符号化。
    ///
    /// 关闭后只记录地址 + 镜像偏移，由服务端用 dSYM 还原。
    /// 这既省去运行时开销，也避免符号名落盘带来的信息泄漏。
    public let symbolicatesInProcess: Bool

    public init(maxSymbolicatedFrames: Int = 32, symbolicatesInProcess: Bool = true) {
        self.maxSymbolicatedFrames = maxSymbolicatedFrames
        self.symbolicatesInProcess = symbolicatesInProcess
    }

    // MARK: - 快照

    public func snapshot(of thread: PerfThreadHandle) throws -> PerfThreadSnapshot {
        var raw = cperf_backtrace_t()
        let result = cperf_backtrace_thread(thread.machPort, &raw)
        guard result == KERN_SUCCESS else {
            throw Self.mapError(result)
        }
        return makeSnapshot(from: raw, thread: threadRef(for: thread.machPort))
    }

    public func snapshotMainThread() throws -> PerfThreadSnapshot {
        guard let handle = PerfBacktrace.mainThreadHandle else {
            throw PerfBacktraceError.mainThreadNotFound
        }
        return try snapshot(of: handle)
    }

    public func snapshotAllThreads() throws -> [PerfThreadSnapshot] {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0

        let result = cperf_thread_list(&threads, &count)
        guard result == KERN_SUCCESS, let threads else {
            throw PerfBacktraceError.threadEnumerationFailed(kernelReturn: result)
        }
        defer { cperf_free_thread_list(threads, count) }

        let currentPort = pthread_mach_thread_np(pthread_self())

        var snapshots: [PerfThreadSnapshot] = []
        snapshots.reserveCapacity(Int(count))

        for index in 0..<Int(count) {
            let port = threads[index]
            // 跳过采集线程自己：它的栈就是这段代码，没有诊断价值，
            // 而且会让每份全线程快照都多出一段完全相同的噪声。
            guard port != currentPort else { continue }

            var raw = cperf_backtrace_t()
            guard cperf_backtrace_thread(port, &raw) == KERN_SUCCESS else { continue }
            snapshots.append(makeSnapshot(from: raw, thread: threadRef(for: port)))
        }
        return snapshots
    }

    // MARK: - 镜像清单

    public func binaryImages() -> [PerfBinaryImage] {
        let count = cperf_image_count()
        var images: [PerfBinaryImage] = []
        images.reserveCapacity(Int(count))

        for index in 0..<count {
            var raw = cperf_image_t()
            guard cperf_image_at_index(index, &raw) else { continue }

            let path = raw.path.map { String(cString: $0) } ?? ""
            images.append(
                PerfBinaryImage(
                    name: (path as NSString).lastPathComponent,
                    path: path,
                    loadAddress: raw.load_address,
                    slide: raw.slide,
                    uuid: raw.has_uuid ? Self.formatUUID(raw.uuid) : nil,
                    architecture: Self.currentArchitecture
                )
            )
        }
        return images
    }

    // MARK: - 转换

    private func makeSnapshot(from raw: cperf_backtrace_t, thread: PerfThreadRef) -> PerfThreadSnapshot {
        let addresses = Self.addresses(from: raw)
        let frames = addresses.enumerated().map { index, address in
            makeFrame(address: address, symbolicate: symbolicatesInProcess && index < maxSymbolicatedFrames)
        }

        return PerfThreadSnapshot(
            thread: thread,
            frames: frames,
            registers: PerfRegisters(
                programCounter: raw.registers.pc,
                linkRegister: raw.registers.lr,
                stackPointer: raw.registers.sp,
                framePointer: raw.registers.fp
            ),
            isTruncated: raw.truncated,
            signature: PerfThreadSnapshot.computeSignature(frames: frames)
        )
    }

    private func makeFrame(address: UInt64, symbolicate: Bool) -> PerfFrame {
        guard symbolicate else {
            return PerfFrame(address: address)
        }

        var symbol = cperf_symbol_t()
        guard cperf_symbolicate(address, &symbol) else {
            return PerfFrame(address: address)
        }

        let imagePath = symbol.image_path.map { String(cString: $0) }
        return PerfFrame(
            address: address,
            imageName: imagePath.map { ($0 as NSString).lastPathComponent },
            // 镜像内偏移：这才是能跨启动、跨设备稳定的标识。
            // 绝对地址受 ASLR 影响每次都不同，用它做聚合等于没做。
            imageOffset: symbol.image_address > 0 ? address - symbol.image_address : nil,
            symbol: symbol.symbol_name.map { String(cString: $0) },
            symbolOffset: symbol.symbol_address > 0 ? address - symbol.symbol_address : nil
        )
    }

    /// 把定长 C 数组里有效的那部分取出来。
    private static func addresses(from raw: cperf_backtrace_t) -> [UInt64] {
        let count = Int(raw.frame_count)
        guard count > 0 else { return [] }

        return withUnsafeBytes(of: raw.frames) { buffer in
            let typed = buffer.bindMemory(to: UInt64.self)
            return Array(typed[0..<min(count, typed.count)])
        }
    }

    private func threadRef(for port: mach_port_t) -> PerfThreadRef {
        var buffer = [CChar](repeating: 0, count: 64)
        cperf_thread_name(port, &buffer, buffer.count)

        // 截到第一个 NUL 再解码，不用已废弃的 String(cString:)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self)

        return PerfThreadRef(
            isMain: cperf_is_main_thread_port(port),
            machPort: port,
            name: name.isEmpty ? nil : name
        )
    }

    private static func formatUUID(_ raw: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                          UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> String {
        withUnsafeBytes(of: raw) { buffer in
            buffer.map { String(format: "%02X", $0) }.joined()
        }
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func mapError(_ kernelReturn: kern_return_t) -> PerfBacktraceError {
        switch kernelReturn {
        case KERN_NOT_SUPPORTED:
            .unsupportedArchitecture
        case KERN_INVALID_ARGUMENT, KERN_FAILURE:
            .mainThreadNotFound
        default:
            .threadStateUnavailable(kernelReturn: kernelReturn)
        }
    }
}
