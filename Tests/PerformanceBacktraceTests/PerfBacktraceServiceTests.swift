import Foundation
import Testing

import PerformanceCore
@testable import PerformanceBacktrace

// MARK: - 被观测的调用链
//
// `@inline(never)` 是必须的：否则优化器会把这几层折叠成一层，
// 帧链里就看不到中间函数了，测试也就失去了意义。

/// 最内层：在这里阻塞，等待外部放行。
@inline(never)
func perfTestInnermostFunction(_ gate: DispatchSemaphore, _ ready: DispatchSemaphore) {
    ready.signal()
    gate.wait()
    // 阻止优化器把这个调用彻底消掉
    _ = readLine.self
}

@inline(never)
func perfTestMiddleFunction(_ gate: DispatchSemaphore, _ ready: DispatchSemaphore) {
    perfTestInnermostFunction(gate, ready)
}

@inline(never)
func perfTestOutermostFunction(_ gate: DispatchSemaphore, _ ready: DispatchSemaphore) {
    perfTestMiddleFunction(gate, ready)
}

/// 在一个独立线程上跑已知调用链，把它的 mach 端口交出来。
final class ProbeThread: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let ready = DispatchSemaphore(value: 0)
    private let portReady = DispatchSemaphore(value: 0)
    private var port: mach_port_t = 0
    private var thread: Thread?

    /// 启动线程并等它进入最内层函数。
    func start(name: String = "perf-probe") {
        let thread = Thread { [self] in
            port = pthread_mach_thread_np(pthread_self())
            portReady.signal()
            perfTestOutermostFunction(gate, ready)
        }
        thread.name = name
        self.thread = thread
        thread.start()

        portReady.wait()
        ready.wait()
    }

    var handle: PerfThreadHandle {
        PerfThreadHandle(machPort: port)
    }

    /// 放行并等线程退出。
    func finish() {
        gate.signal()
        while thread?.isFinished == false {
            usleep(1_000)
        }
    }
}

// MARK: -

@Suite("跨线程栈回溯")
struct PerfBacktraceServiceTests {

    @Test("能抓到另一个线程的栈——这是上一版做不到的")
    func capturesOtherThreadStack() throws {
        let probe = ProbeThread()
        probe.start()
        defer { probe.finish() }

        let service = PerfBacktraceService()
        let snapshot = try service.snapshot(of: probe.handle)

        #expect(snapshot.frames.count > 1)
        #expect(snapshot.registers.programCounter != 0)
        #expect(snapshot.registers.stackPointer != 0)

        // 关键断言：抓到的是**探针线程**的调用链，不是调用 snapshot 的这个线程。
        // 上一版用 backtrace() 在这里只会拿到测试线程自己的栈。
        let symbols = snapshot.frames.compactMap(\.symbol).joined(separator: "\n")
        #expect(symbols.contains("perfTestInnermostFunction"))
        #expect(symbols.contains("perfTestMiddleFunction"))
        #expect(symbols.contains("perfTestOutermostFunction"))
    }

    @Test("帧顺序由内向外")
    func framesAreOrderedInnermostFirst() throws {
        let probe = ProbeThread()
        probe.start()
        defer { probe.finish() }

        let snapshot = try PerfBacktraceService().snapshot(of: probe.handle)
        let symbols = snapshot.frames.compactMap(\.symbol)

        let innermost = try #require(symbols.firstIndex { $0.contains("perfTestInnermostFunction") })
        let middle = try #require(symbols.firstIndex { $0.contains("perfTestMiddleFunction") })
        let outermost = try #require(symbols.firstIndex { $0.contains("perfTestOutermostFunction") })

        #expect(innermost < middle)
        #expect(middle < outermost)
    }

    @Test("被观测线程在回溯后恢复运行，没有被永久挂起")
    func resumesTargetThread() throws {
        let probe = ProbeThread()
        probe.start()

        let service = PerfBacktraceService()
        // 连抓多次：任何一次漏掉 thread_resume 都会让线程永久挂起，
        // 若那是主线程，app 就被监控本身搞死了
        for _ in 0..<20 {
            _ = try service.snapshot(of: probe.handle)
        }

        // 能正常放行退出，说明线程确实是活的
        probe.finish()
        #expect(Bool(true))
    }

    @Test("快照带上线程名与主线程标记")
    func populatesThreadReference() throws {
        let probe = ProbeThread()
        probe.start(name: "my-probe-thread")
        defer { probe.finish() }

        let snapshot = try PerfBacktraceService().snapshot(of: probe.handle)
        #expect(snapshot.thread.name == "my-probe-thread")
        #expect(!snapshot.thread.isMain)
        #expect(snapshot.thread.machPort == probe.handle.machPort)
    }

    @Test("可以抓自己的栈，且不会把自己挂起")
    func capturesCurrentThreadWithoutSuspending() throws {
        let handle = PerfThreadHandle(machPort: pthread_mach_thread_np(pthread_self()))
        let snapshot = try PerfBacktraceService().snapshot(of: handle)

        #expect(snapshot.frames.count > 1)
        let symbols = snapshot.frames.compactMap(\.symbol).joined(separator: "\n")
        #expect(symbols.contains("capturesCurrentThreadWithoutSuspending"))
    }

    @Test("主线程登记后可从后台线程抓主线程的栈")
    func capturesMainThreadFromBackground() async throws {
        await MainActor.run { PerfBacktrace.registerMainThread() }

        let snapshot = try await Task.detached {
            try PerfBacktraceService().snapshotMainThread()
        }.value

        #expect(snapshot.thread.isMain)
        #expect(snapshot.frames.count > 1)
    }

    @Test("无效端口返回错误而不是崩溃")
    func rejectsInvalidPort() {
        #expect(throws: (any Error).self) {
            _ = try PerfBacktraceService().snapshot(of: PerfThreadHandle(machPort: 0))
        }
    }

    @Test("全线程快照覆盖探针线程，且不含采集线程自己")
    func capturesAllThreads() throws {
        let probe = ProbeThread()
        probe.start(name: "probe-in-all")
        defer { probe.finish() }

        let snapshots = try PerfBacktraceService().snapshotAllThreads()
        #expect(snapshots.count > 1)
        #expect(snapshots.contains { $0.thread.name == "probe-in-all" })

        // 采集线程自己的栈就是这段代码，没有诊断价值，会成为每份快照里的固定噪声
        let currentPort = pthread_mach_thread_np(pthread_self())
        #expect(!snapshots.contains { $0.thread.machPort == currentPort })
    }
}

// MARK: - 符号化与镜像

@Suite("符号化与镜像清单")
struct PerfSymbolicationTests {
    @Test("栈帧带镜像偏移，这是服务端符号化的必要输入")
    func framesCarryImageOffset() throws {
        let handle = PerfThreadHandle(machPort: pthread_mach_thread_np(pthread_self()))
        let snapshot = try PerfBacktraceService().snapshot(of: handle)

        let symbolicated = snapshot.frames.prefix(8)
        #expect(symbolicated.contains { $0.imageName != nil })
        // 绝对地址受 ASLR 影响每次运行都不同，只有镜像偏移能在 dSYM 里定位
        #expect(symbolicated.contains { $0.imageOffset != nil })
    }

    @Test("关闭进程内符号化后只留地址")
    func skipsSymbolicationWhenDisabled() throws {
        let handle = PerfThreadHandle(machPort: pthread_mach_thread_np(pthread_self()))
        let service = PerfBacktraceService(symbolicatesInProcess: false)
        let snapshot = try service.snapshot(of: handle)

        #expect(snapshot.frames.allSatisfy { $0.symbol == nil })
        #expect(snapshot.frames.allSatisfy { $0.address != 0 })
    }

    @Test("只符号化栈顶若干帧，避免在卡顿现场反复拿 dyld 锁")
    func limitsSymbolicatedFrameCount() throws {
        let probe = ProbeThread()
        probe.start()
        defer { probe.finish() }

        let service = PerfBacktraceService(maxSymbolicatedFrames: 2)
        let snapshot = try service.snapshot(of: probe.handle)

        guard snapshot.frames.count > 3 else { return }
        #expect(snapshot.frames.dropFirst(2).allSatisfy { $0.symbol == nil && $0.imageName == nil })
    }

    @Test("镜像清单带 UUID 与 slide")
    func listsBinaryImages() {
        let images = PerfBacktraceService().binaryImages()

        #expect(images.count > 1)
        // 主可执行文件一定在列表里
        #expect(images.contains { !$0.name.isEmpty })

        let withUUID = images.filter { $0.uuid != nil }
        #expect(!withUUID.isEmpty)
        // UUID 是 16 字节的十六进制大写串
        #expect(withUUID.allSatisfy { $0.uuid?.count == 32 })
    }

    @Test("同一处调用栈的签名稳定，可用于聚合")
    func signatureIsStableAcrossSamples() throws {
        let probe = ProbeThread()
        probe.start()
        defer { probe.finish() }

        let service = PerfBacktraceService()
        let first = try service.snapshot(of: probe.handle)
        let second = try service.snapshot(of: probe.handle)

        // 线程卡在同一处不动，两次采样应聚合到同一个签名。
        // 上一版这里恒为 "unknown"，热点分析永远输出 unknown: 100%
        #expect(first.signature == second.signature)
        #expect(first.signature != 0)
    }
}
