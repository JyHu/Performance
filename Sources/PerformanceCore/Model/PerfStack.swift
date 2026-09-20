import Foundation

/// 调用栈中的一帧。
public struct PerfFrame: Codable, Sendable, Hashable {
    /// 程序计数器地址。
    public let address: UInt64
    /// 所属二进制镜像名（`dladdr` 的 `dli_fname` 取 basename）。
    public let imageName: String?
    /// 相对镜像加载基址的偏移。
    ///
    /// 这个字段是服务端符号化的关键：ASLR 让绝对地址每次运行都不同，
    /// 只有 `镜像 UUID + 偏移` 才能在 dSYM 里定位到源码位置。
    public let imageOffset: UInt64?
    /// `dladdr` 能解析到的符号名。Release 构建下常为 nil 或只有导出符号。
    public let symbol: String?
    /// 相对符号起始地址的偏移。
    public let symbolOffset: UInt64?

    public init(
        address: UInt64,
        imageName: String? = nil,
        imageOffset: UInt64? = nil,
        symbol: String? = nil,
        symbolOffset: UInt64? = nil
    ) {
        self.address = address
        self.imageName = imageName
        self.imageOffset = imageOffset
        self.symbol = symbol
        self.symbolOffset = symbolOffset
    }
}

extension PerfFrame: CustomStringConvertible {
    public var description: String {
        let image = imageName ?? "???"
        if let symbol, let symbolOffset {
            return "\(image) \(symbol) + \(symbolOffset)"
        }
        if let imageOffset {
            return "\(image) + \(imageOffset)"
        }
        return String(format: "%@ 0x%llx", image, address)
    }
}

/// 关键寄存器快照。
///
/// 死锁判定需要它：连续多次采样若 PC/LR/SP/FP 完全不变，
/// 说明线程确实停在原地，而不只是执行得慢。
public struct PerfRegisters: Codable, Sendable, Hashable {
    public let programCounter: UInt64
    public let linkRegister: UInt64
    public let stackPointer: UInt64
    public let framePointer: UInt64

    public init(programCounter: UInt64, linkRegister: UInt64, stackPointer: UInt64, framePointer: UInt64) {
        self.programCounter = programCounter
        self.linkRegister = linkRegister
        self.stackPointer = stackPointer
        self.framePointer = framePointer
    }
}

/// 某个线程在某一刻的调用栈快照。
public struct PerfThreadSnapshot: Codable, Sendable, Hashable {
    public let thread: PerfThreadRef
    public let frames: [PerfFrame]
    public let registers: PerfRegisters
    /// 栈是否被截断（达到最大帧数上限）。
    public let isTruncated: Bool

    /// 基于 PC 序列的稳定哈希，用于把同一处卡顿的多次采样聚合到一起。
    ///
    /// 上一版试图做同样的事，但产出栈的格式（`"符号名@0x地址"`）
    /// 和解析栈的格式（`"pc: ..."` 前缀）对不上，
    /// 于是聚合键恒为 `"unknown"`，整个热点分析恒定输出 `unknown: 100%`。
    /// 这里直接在产出侧算好签名，不做字符串往返。
    public let signature: UInt64

    public init(
        thread: PerfThreadRef,
        frames: [PerfFrame],
        registers: PerfRegisters,
        isTruncated: Bool,
        signature: UInt64
    ) {
        self.thread = thread
        self.frames = frames
        self.registers = registers
        self.isTruncated = isTruncated
        self.signature = signature
    }

    /// 用镜像偏移（而非绝对地址）计算签名，使其跨进程、跨启动稳定。
    ///
    /// 用绝对地址会因 ASLR 每次启动都不同，聚合将完全失效。
    public static func computeSignature(frames: [PerfFrame]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a 64 位偏移基准
        for frame in frames {
            let value = frame.imageOffset ?? frame.address
            withUnsafeBytes(of: value.littleEndian) { bytes in
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash = hash &* 0x0000_0100_0000_01B3
                }
            }
        }
        return hash
    }
}

/// 一个已加载的二进制镜像。
///
/// 崩溃报告和卡顿堆栈落盘时必须带上镜像清单，服务端才能用 `atos`/`symbolicatecrash`
/// 还原符号。上一版只在文档里写了 atos 脚本示例，代码侧从未产出 UUID 和 slide，
/// 那份脚本实际上无法使用。
public struct PerfBinaryImage: Codable, Sendable, Hashable {
    public let name: String
    public let path: String
    /// 镜像加载基址。
    public let loadAddress: UInt64
    /// ASLR 滑动量。
    public let slide: UInt64
    /// LC_UUID，16 字节十六进制大写串。
    public let uuid: String?
    public let architecture: String?

    public init(
        name: String,
        path: String,
        loadAddress: UInt64,
        slide: UInt64,
        uuid: String?,
        architecture: String?
    ) {
        self.name = name
        self.path = path
        self.loadAddress = loadAddress
        self.slide = slide
        self.uuid = uuid
        self.architecture = architecture
    }
}

// MARK: - 契约

/// 栈回溯能力的契约。
///
/// 协议定义在 `PerformanceCore`、实现在 `PerfBacktrace`：
/// 这样 `PerfMonitorContext` 能携带这项能力，而 Core 不必反向依赖 Backtrace，
/// 采集器也可以在测试里注入一个假的实现。
public protocol PerfBacktraceProviding: Sendable {
    /// 抓取**指定**线程的调用栈。
    ///
    /// 「指定线程」是这套设计存在的全部理由。上一版的 `captureMainThreadStack()`
    /// 用的是 C 的 `backtrace()`，而该 API 只能抓当前调用线程——
    /// 它的四个调用方全在后台队列上，于是所有标着「主线程堆栈」的数据
    /// 其实都是采集线程自己的栈，对排查毫无价值。
    func snapshot(of thread: PerfThreadHandle) throws -> PerfThreadSnapshot

    /// 抓取主线程的调用栈。
    func snapshotMainThread() throws -> PerfThreadSnapshot

    /// 抓取进程内全部线程的调用栈。
    func snapshotAllThreads() throws -> [PerfThreadSnapshot]

    /// 当前已加载的镜像清单，供服务端符号化。
    func binaryImages() -> [PerfBinaryImage]
}

/// mach 线程端口的强类型包装。
public struct PerfThreadHandle: Hashable, Sendable {
    public let machPort: UInt32

    public init(machPort: UInt32) {
        self.machPort = machPort
    }
}

public enum PerfBacktraceError: Error, Sendable {
    /// 无法获取线程列表。
    case threadEnumerationFailed(kernelReturn: Int32)
    /// 挂起线程失败。
    case suspendFailed(kernelReturn: Int32)
    /// 读取线程寄存器失败。
    case threadStateUnavailable(kernelReturn: Int32)
    /// 当前 CPU 架构不支持。
    case unsupportedArchitecture
    /// 找不到主线程。
    case mainThreadNotFound
}
