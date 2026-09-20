import Foundation
import Testing

@testable import PerformanceCore

// MARK: - 测试用监测器

struct DummyOptions: PerfMonitorOptions {
    var interval: PerfDuration = .seconds(1)
    var threshold: Double = 80
    init() {}
}

actor DummyMonitor: PerfMonitor {
    nonisolated static let descriptor = PerfMonitorDescriptor(
        id: "dummy",
        displayName: "Dummy",
        kinds: [SampleMetric.kind],
        platforms: .all
    )

    private var options: DummyOptions
    private let context: PerfMonitorContext
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(options: DummyOptions, context: PerfMonitorContext) {
        self.options = options
        self.context = context
    }

    var currentOptions: DummyOptions { options }

    func start() async throws {
        startCount += 1
        context.recorder.record(SampleMetric(value: options.threshold, label: "start", counts: []))
    }

    func stop() async {
        stopCount += 1
    }

    func apply(_ options: DummyOptions) async {
        self.options = options
    }
}

/// 与 DummyMonitor 声明同一个 kind，用于验证冲突检测。
actor ConflictingMonitor: PerfMonitor {
    nonisolated static let descriptor = PerfMonitorDescriptor(
        id: "conflicting",
        displayName: "Conflicting",
        kinds: [SampleMetric.kind],
        platforms: .all
    )

    init(options: DummyOptions, context: PerfMonitorContext) {}
    func start() async throws {}
    func stop() async {}
}

/// 只支持 macOS，用于验证平台过滤。
actor MacOnlyMonitor: PerfMonitor {
    nonisolated static let descriptor = PerfMonitorDescriptor(
        id: "mac-only",
        displayName: "Mac Only",
        kinds: [OtherMetric.kind],
        platforms: .macOS
    )

    init(options: DummyOptions, context: PerfMonitorContext) {}
    func start() async throws {}
    func stop() async {}
}

// MARK: -

@Suite("PerfConfiguration")
struct PerformanceConfigurationTests {
    private func makeContext(sink: any PerfEventSink = PerfNullSink()) -> PerfMonitorContext {
        let clock = PerfManualClock()
        return PerfMonitorContext(
            recorder: PerfRecorder(sink: sink, sessionID: PerfSessionID(rawValue: "test"), clock: clock),
            scheduler: PerfManualScheduler(clock: clock),
            clock: clock,
            log: .disabled,
            lifecycle: PerfManualAppLifecycle()
        )
    }

    @Test("enable 只需覆盖关心的字段，其余取默认值")
    func appliesPartialConfiguration() async {
        var config = PerfConfiguration()
        config.enable(DummyMonitor.self) { $0.threshold = 95 }

        let registration = try! #require(config.registrations.first)
        let monitor = registration.makeMonitor(context: makeContext())
        #expect(monitor.descriptor.id == "dummy")

        // 通过启动时记录的值间接验证配置生效
        let sink = PerfCollectingSink()
        let configured = registration.makeMonitor(context: makeContext(sink: sink))
        try? await configured.start()
        #expect(sink.payloads(of: SampleMetric.self).first?.value == 95)
    }

    @Test("重复 enable 覆盖先前配置，不产生重复注册")
    func reEnableOverwrites() {
        var config = PerfConfiguration()
        config.enable(DummyMonitor.self) { $0.threshold = 10 }
        config.enable(DummyMonitor.self) { $0.threshold = 20 }

        #expect(config.registrations.count == 1)
    }

    @Test("disable 移除注册")
    func disableRemoves() {
        var config = PerfConfiguration()
        config.enable(DummyMonitor.self)
        #expect(config.isEnabled(DummyMonitor.self))

        config.disable(DummyMonitor.self)
        #expect(!config.isEnabled(DummyMonitor.self))
        #expect(config.registrations.isEmpty)
    }

    @Test("注册顺序被保留——启动顺序对依赖前置条件的监测器有意义")
    func preservesRegistrationOrder() {
        var config = PerfConfiguration()
        config.enable(DummyMonitor.self)
        config.enable(MacOnlyMonitor.self)

        #expect(config.enabledMonitorIDs == ["dummy", "mac-only"])
    }

    @Test("两个监测器声明同一 kind 时给出告警")
    func detectsDuplicateKind() {
        var config = PerfConfiguration()
        config.enable(DummyMonitor.self)
        config.enable(ConflictingMonitor.self)

        let warnings = config.validate()
        let hasDuplicate = warnings.contains {
            if case .duplicateKind(let kind, _, _) = $0 { return kind == SampleMetric.kind }
            return false
        }
        #expect(hasDuplicate)
    }

    @Test("平台不匹配的监测器被标记出来，而不是静默空转")
    func detectsUnsupportedPlatform() {
        var config = PerfConfiguration()
        config.enable(MacOnlyMonitor.self)

        let warnings = config.validate()
        let hasUnsupported = warnings.contains {
            if case .unsupportedPlatform(let id) = $0 { return id == "mac-only" }
            return false
        }

        #if os(macOS)
        #expect(!hasUnsupported)
        #else
        #expect(hasUnsupported)
        #endif
    }

    @Test("单分片上限超过总配额时告警")
    func detectsShardLargerThanQuota() {
        var config = PerfConfiguration()
        config.storage.maxShardBytes = .megabytes(100)
        config.storage.totalQuota = .megabytes(50)

        #expect(config.validate().contains(.shardLargerThanQuota))
    }

    @Test("默认配置无告警")
    func defaultConfigurationIsClean() {
        let config = PerfConfiguration()
        #expect(config.validate().isEmpty)
    }
}

// MARK: - 热更新

@Suite("PerfOptionsBox")
struct PerfOptionsBoxTests {
    @Test("更新后读到的是新值")
    func reflectsUpdates() {
        let box = PerfOptionsBox(DummyOptions())
        #expect(box.read(\.threshold) == 80)

        box.mutate { $0.threshold = 60 }
        #expect(box.read(\.threshold) == 60)

        var replacement = DummyOptions()
        replacement.threshold = 42
        box.update(replacement)
        #expect(box.value.threshold == 42)
    }

    @Test("并发读写不产生竞争")
    func isSafeUnderConcurrency() async {
        let box = PerfOptionsBox(DummyOptions())

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { box.mutate { $0.threshold = Double(i) } }
                group.addTask { _ = box.value }
            }
        }

        #expect(box.read(\.threshold) >= 0)
    }

    @Test("监测器可在运行时接收新配置")
    func monitorAcceptsHotUpdate() async {
        let clock = PerfManualClock()
        let context = PerfMonitorContext(
            recorder: PerfRecorder(sink: PerfNullSink(), sessionID: PerfSessionID(rawValue: "s"), clock: clock),
            scheduler: PerfManualScheduler(clock: clock),
            clock: clock,
            log: .disabled,
            lifecycle: PerfManualAppLifecycle()
        )
        let monitor = DummyMonitor(options: DummyOptions(), context: context)
        #expect(await monitor.currentOptions.threshold == 80)

        var updated = DummyOptions()
        updated.threshold = 55
        await monitor.apply(updated)

        #expect(await monitor.currentOptions.threshold == 55)
    }
}

// MARK: - 生命周期

@Suite("PerfAppLifecycle")
struct PerfAppLifecycleTests {
    @Test("观察者收到事件")
    func deliversEvents() async {
        let lifecycle = PerfManualAppLifecycle()
        let received = Recorder()

        lifecycle.observe { event, _ in
            Task { await received.append(event) }
        }
        lifecycle.send(.didEnterBackground)
        lifecycle.send(.willEnterForeground)

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await received.events == [.didEnterBackground, .willEnterForeground])
    }

    @Test("移除后不再收到事件")
    func stopsAfterRemoval() async {
        let lifecycle = PerfManualAppLifecycle()
        let received = Recorder()

        let token = lifecycle.observe { event, _ in
            Task { await received.append(event) }
        }
        lifecycle.send(.didBecomeActive)
        lifecycle.removeObserver(token)
        lifecycle.send(.willResignActive)

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await received.events == [.didBecomeActive])
    }

    private actor Recorder {
        private(set) var events: [PerfAppLifecycleEvent] = []
        func append(_ event: PerfAppLifecycleEvent) { events.append(event) }
    }
}

// MARK: - 脱敏

@Suite("PerfRedactionPolicy")
struct PerfRedactionTests {
    @Test("默认策略去掉 query，保留 host 与路径")
    func stripsQueryByDefault() {
        let policy = PerfRedactionPolicy.default
        let result = policy.redact(urlString: "https://api.example.com/v1/orders/12345?token=secret&sig=abc")
        #expect(result == "https://api.example.com/v1/orders/12345")
    }

    @Test("严格策略连路径一起去掉")
    func stripsPathInStrictMode() {
        let result = PerfRedactionPolicy.strict.redact(urlString: "https://api.example.com/v1/users/42?k=v")
        #expect(result == "https://api.example.com")
    }

    @Test("URL 里的用户名密码始终被移除")
    func alwaysStripsCredentials() {
        let result = PerfRedactionPolicy.disabled.redact(urlString: "https://alice:hunter2@example.com/x")
        #expect(!result.contains("alice"))
        #expect(!result.contains("hunter2"))
    }

    @Test("白名单之外的 host 被替换，且结果仍是合法 URL")
    func replacesDisallowedHost() {
        var policy = PerfRedactionPolicy.default
        policy.allowedURLHosts = ["api.example.com"]

        #expect(policy.redact(urlString: "https://api.example.com/a").contains("api.example.com"))

        let redacted = policy.redact(urlString: "https://tracker.thirdparty.com/a")
        #expect(!redacted.contains("thirdparty"))
        #expect(redacted.contains(PerfRedactionPolicy.redactedHost))
        // 替换后必须仍可解析，否则下游重建 URL 时会回退到兜底路径
        #expect(URLComponents(string: redacted) != nil)
    }

    @Test("URL 无法解析时返回占位符，不会泄漏原始字符串")
    func failsClosedOnUnparseableURL() {
        // 脱敏一旦失败，宁可丢数据也不能把未处理的内容放出去
        let result = PerfRedactionPolicy.strict.redact(urlString: "https://exa mple.com/secret?token=abc")
        #expect(result == PerfRedactionPolicy.redactedURLPlaceholder)
        #expect(!result.contains("token"))
        #expect(!result.contains("secret"))
    }

    @Test("home 目录路径被相对化，隐去用户名")
    func relativizesHomePath() {
        let path = NSHomeDirectory() + "/Library/Caches/foo.db"
        let result = PerfRedactionPolicy.default.redact(path: path)
        #expect(result == "~/Library/Caches/foo.db")
        #expect(!result.contains(NSHomeDirectory()))
    }

    @Test("关闭符号名后栈帧只留镜像偏移")
    func dropsSymbolsWhenDisabled() {
        let frames = [
            PerfFrame(address: 0x1000, imageName: "App", imageOffset: 0x100, symbol: "secretInternalName", symbolOffset: 8)
        ]
        let redacted = PerfRedactionPolicy.strict.redact(frames: frames)

        #expect(redacted[0].symbol == nil)
        #expect(redacted[0].symbolOffset == nil)
        // 偏移保留，服务端仍可用 dSYM 还原
        #expect(redacted[0].imageOffset == 0x100)
        #expect(redacted[0].imageName == "App")
    }

    @Test("保留符号名时栈帧原样返回")
    func keepsSymbolsWhenEnabled() {
        let frames = [PerfFrame(address: 0x1000, imageName: "App", imageOffset: 0x100, symbol: "foo", symbolOffset: 8)]
        #expect(PerfRedactionPolicy.default.redact(frames: frames) == frames)
    }
}
