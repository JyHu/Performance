import CPerfCrash
import Foundation
import PerformanceBacktrace
import PerformanceCore

// MARK: - 载荷

/// 上次运行的崩溃。
///
/// 注意它是在**下一次启动**时上报的：崩溃现场只写裸字节，
/// 解析和上报都留到进程健康时做。
public struct PerfCrashReport: PerfPayload, Equatable {
    public static let kind: PerfKind = "crash.signal"

    /// 信号编号。
    public let signal: Int
    public let signalName: String
    /// 崩溃发生的时刻。
    public let crashedAt: Date
    /// 崩溃线程是否是主线程。
    public let onMainThread: Bool
    public let registers: PerfRegisters?
    /// 崩溃线程的调用栈（只有地址，符号化留给服务端）。
    public let frames: [PerfFrame]
    /// 镜像清单，服务端用它 + dSYM 还原符号。
    ///
    /// 没有这份清单，上面的地址在服务端毫无意义——ASLR 让每次运行的
    /// 绝对地址都不同。上一版只在文档里写了 atos 脚本，
    /// 代码侧从未产出 UUID 和 slide，那份脚本实际无法使用。
    public let binaryImages: [PerfBinaryImage]
    /// 裸报告是否完整（含结束标记）。
    ///
    /// 不完整意味着进程在写报告的过程中就被杀了，
    /// 数据可用但要知道它是残缺的。
    public let isComplete: Bool

    public init(
        signal: Int,
        signalName: String,
        crashedAt: Date,
        onMainThread: Bool,
        registers: PerfRegisters?,
        frames: [PerfFrame],
        binaryImages: [PerfBinaryImage],
        isComplete: Bool
    ) {
        self.signal = signal
        self.signalName = signalName
        self.crashedAt = crashedAt
        self.onMainThread = onMainThread
        self.registers = registers
        self.frames = frames
        self.binaryImages = binaryImages
        self.isComplete = isComplete
    }
}

/// 未捕获的 Objective-C 异常。
public struct PerfUncaughtExceptionReport: PerfPayload, Equatable {
    public static let kind: PerfKind = "crash.uncaught_exception"

    public let name: String
    public let reason: String?
    public let callStack: [String]

    public init(name: String, reason: String?, callStack: [String]) {
        self.name = name
        self.reason = reason
        self.callStack = callStack
    }
}

// MARK: - 裸报告解析

/// 把崩溃现场写下的裸文本解析成结构化数据。
///
/// 在**下次启动**时执行，此时进程是健康的，可以随意分配内存、做字符串处理。
public enum PerfCrashReportParser {
    public static func parse(contentsOf url: URL) -> PerfCrashReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(text: String(decoding: data, as: UTF8.self))
    }

    static func parse(text: String) -> PerfCrashReport? {
        var signal = 0
        var timestamp: TimeInterval = 0
        var onMainThread = false
        var registers: PerfRegisters?
        var frames: [PerfFrame] = []
        var images: [PerfBinaryImage] = []
        var isComplete = false

        var section = Section.header
        enum Section { case header, frames, images }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ").map(String.init)
            guard let head = parts.first else { continue }

            switch head {
            case "signal":
                signal = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            case "time":
                timestamp = parts.count > 1 ? TimeInterval(parts[1]) ?? 0 : 0
            case "thread":
                onMainThread = parts.contains("main")
            case "registers" where parts.count >= 5:
                registers = PerfRegisters(
                    programCounter: parseHex(parts[1]),
                    linkRegister: parseHex(parts[2]),
                    stackPointer: parseHex(parts[3]),
                    framePointer: parseHex(parts[4])
                )
            case "frames":
                section = .frames
            case "images":
                section = .images
            case "end":
                isComplete = true
            default:
                switch section {
                case .frames:
                    frames.append(PerfFrame(address: parseHex(head)))
                case .images where parts.count >= 4:
                    let path = parts[3...].joined(separator: " ")
                    images.append(
                        PerfBinaryImage(
                            name: (path as NSString).lastPathComponent,
                            path: path,
                            loadAddress: parseHex(parts[0]),
                            slide: parseHex(parts[1]),
                            uuid: parts[2] == "-" ? nil : parts[2],
                            architecture: nil
                        )
                    )
                default:
                    break
                }
            }
        }

        // 连信号编号和栈都没有的报告没有任何价值
        guard signal != 0 || !frames.isEmpty else { return nil }

        return PerfCrashReport(
            signal: signal,
            signalName: signalName(for: signal),
            crashedAt: Date(timeIntervalSince1970: timestamp),
            onMainThread: onMainThread,
            registers: registers,
            frames: frames,
            binaryImages: images,
            isComplete: isComplete
        )
    }

    private static func parseHex(_ text: String) -> UInt64 {
        let stripped = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return UInt64(stripped, radix: 16) ?? 0
    }

    static func signalName(for signal: Int) -> String {
        switch Int32(signal) {
        case SIGSEGV: "SIGSEGV"
        case SIGBUS: "SIGBUS"
        case SIGILL: "SIGILL"
        case SIGFPE: "SIGFPE"
        case SIGABRT: "SIGABRT"
        case SIGTRAP: "SIGTRAP"
        case 0: "TEST"
        default: "SIG(\(signal))"
        }
    }
}

// MARK: - 监测器

public struct PerfCrashMonitorOptions: PerfMonitorOptions {
    /// 裸报告的存放目录。nil 表示用存储层的 `crash/` 目录。
    public var reportDirectory: URL?

    /// 是否安装 signal handler。
    ///
    /// 关掉可以只依赖 MetricKit 的 `MXCrashDiagnostic`——那条链路无侵入、
    /// 栈已由系统符号化，代价是最长滞后 24 小时，且拿不到业务上下文。
    public var installsSignalHandlers: Bool = true

    /// 是否接管未捕获的 Objective-C 异常。
    public var installsExceptionHandler: Bool = true

    public init() {}
}

/// 崩溃捕获。
public actor PerfCrashMonitor: PerfMonitor {
    public nonisolated static let descriptor = PerfMonitorDescriptor(
        id: PerfCrash.monitorID,
        displayName: "崩溃",
        kinds: [PerfCrashReport.kind, PerfUncaughtExceptionReport.kind],
        platforms: .all
    )

    private var options: PerfCrashMonitorOptions
    private let context: PerfMonitorContext
    private var reportURL: URL?
    private var isInstalled = false

    public init(options: PerfCrashMonitorOptions, context: PerfMonitorContext) {
        self.options = options
        self.context = context.scoped(to: Self.descriptor.id)
    }

    public func start() async throws {
        guard !isInstalled else { return }

        let directory = try resolveReportDirectory()
        let url = directory.appendingPathComponent("pending.crash")
        reportURL = url

        // 先把上次留下的报告捞出来上报，再安装新的 handler。
        // 顺序不能反：安装用的是 O_EXCL，旧文件还在的话新崩溃根本写不进去。
        await reportPendingCrashIfNeeded(at: url)

        if options.installsSignalHandlers {
            let installed = url.path.withCString { cperf_crash_install($0) }
            if !installed {
                context.log.error("安装 signal handler 失败")
            }
        }
        if options.installsExceptionHandler {
            PerfExceptionHandler.install(recorder: context.recorder)
        }
        isInstalled = true
    }

    public func stop() async {
        if options.installsSignalHandlers {
            cperf_crash_uninstall()
        }
        if options.installsExceptionHandler {
            PerfExceptionHandler.uninstall()
        }
        isInstalled = false
    }

    public func apply(_ options: PerfCrashMonitorOptions) async {
        self.options = options
    }

    /// 上次运行是否崩溃过。可在 `start()` 之前查询。
    public func hasPendingCrashReport() -> Bool {
        guard let reportURL else { return false }
        return FileManager.default.fileExists(atPath: reportURL.path)
    }

    // MARK: - 内部

    private func resolveReportDirectory() throws -> URL {
        let directory: URL
        if let configured = options.reportDirectory {
            directory = configured
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            guard let caches else {
                throw CocoaError(.fileNoSuchFile)
            }
            directory = caches
                .appendingPathComponent("Performance", isDirectory: true)
                .appendingPathComponent("crash", isDirectory: true)
        }

        // 目录必须提前建好——崩溃现场不能创建目录，那会调用 malloc
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func reportPendingCrashIfNeeded(at url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let report = PerfCrashReportParser.parse(contentsOf: url) else {
            context.log.warning("发现崩溃报告但解析失败，已丢弃")
            return
        }

        context.recorder.record(
            report,
            severity: .critical,
            thread: report.onMainThread ? .main : nil,
            // 时间戳取**崩溃发生**的时刻，不是现在读到它的时刻。
            // 否则这条记录会落在本次启动的时间线上，
            // 看起来像是刚启动就崩了。
            timestamp: report.crashedAt,
            uptimeNanos: context.clock.uptimeNanos
        )
        context.log.info("上报上次运行的崩溃：\(report.signalName)，\(report.frames.count) 帧")
    }
}

// MARK: - Objective-C 异常

/// 未捕获异常处理器。
///
/// 与 signal handler 是互补关系：未捕获的 ObjC 异常最终会走到 `abort()`
/// 进而触发 SIGABRT，但那时异常的名字和 reason 已经丢了。
/// 在这里先接一手，才能拿到「为什么抛的」。
enum PerfExceptionHandler {
    private static let storage = HandlerStorage()

    static func install(recorder: PerfRecorder) {
        storage.recorder = recorder
        storage.previous = NSGetUncaughtExceptionHandler()

        NSSetUncaughtExceptionHandler { exception in
            PerfExceptionHandler.handle(exception)
        }
    }

    static func uninstall() {
        NSSetUncaughtExceptionHandler(storage.previous)
        storage.recorder = nil
        storage.previous = nil
    }

    private static func handle(_ exception: NSException) {
        storage.recorder?.record(
            PerfUncaughtExceptionReport(
                name: exception.name.rawValue,
                reason: exception.reason,
                callStack: exception.callStackSymbols
            ),
            severity: .critical
        )

        // 转交给先前的处理器，不吞掉异常——
        // 否则会破坏其他崩溃收集 SDK 和系统自身的崩溃日志
        storage.previous?(exception)
    }

    private final class HandlerStorage: @unchecked Sendable {
        private let lock = PerfLock()
        private var recorderValue: PerfRecorder?
        private var previousValue: (@convention(c) (NSException) -> Void)?

        var recorder: PerfRecorder? {
            get { lock.withLock { recorderValue } }
            set { lock.withLock { recorderValue = newValue } }
        }

        var previous: (@convention(c) (NSException) -> Void)? {
            get { lock.withLock { previousValue } }
            set { lock.withLock { previousValue = newValue } }
        }
    }
}
