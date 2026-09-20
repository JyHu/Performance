import Foundation
import Testing

@testable import PerformanceCore

// MARK: - 测试用载荷

struct SampleMetric: PerfPayload, Equatable {
    static let kind: PerfKind = "sample.metric"
    static let schemaVersion = 3

    let value: Double
    let label: String
    let counts: [Int]
}

struct OtherMetric: PerfPayload, Equatable {
    static let kind: PerfKind = "sample.other"
    let flag: Bool
}

// MARK: - PerfKind

@Suite("PerfKind")
struct PerfKindTests {
    @Test("点分标识可拆出大类与叶子名")
    func splitsNamespace() {
        let kind: PerfKind = "hang.anr"
        #expect(kind.group == "hang")
        #expect(kind.leaf == "anr")
    }

    @Test("没有点号时整体即大类")
    func handlesFlatIdentifier() {
        let kind: PerfKind = "heartbeat"
        #expect(kind.group == "heartbeat")
        #expect(kind.leaf == "")
    }

    @Test("多级命名空间只按第一个点拆分，其余归入叶子名")
    func splitsOnlyOnFirstDot() {
        let kind: PerfKind = "trace.page.load"
        #expect(kind.group == "trace")
        #expect(kind.leaf == "page.load")
    }
}

// MARK: - PerfSeverity

@Suite("PerfSeverity")
struct PerfSeverityTests {
    @Test("严重度可比较，顺序由低到高")
    func ordersByLevel() {
        #expect(PerfSeverity.debug < .info)
        #expect(PerfSeverity.info < .warning)
        #expect(PerfSeverity.warning < .error)
        #expect(PerfSeverity.error < .critical)
    }

    @Test("按最低严重度过滤")
    func filtersByMinimum() {
        let all = PerfSeverity.allCases
        let kept = all.filter { $0 >= .warning }
        #expect(kept == [.warning, .error, .critical])
    }
}

// MARK: - PerfDuration

@Suite("PerfDuration")
struct PerfDurationTests {
    @Test("各单位换算一致")
    func convertsUnits() {
        #expect(PerfDuration.seconds(1).nanoseconds == 1_000_000_000)
        #expect(PerfDuration.milliseconds(1).nanoseconds == 1_000_000)
        #expect(PerfDuration.milliseconds(250).seconds == 0.25)
        #expect(PerfDuration.days(1).nanoseconds == 86_400 * 1_000_000_000)
    }

    @Test("减法饱和到零，不会下溢")
    func subtractionSaturates() {
        let result = PerfDuration.milliseconds(10) - PerfDuration.seconds(1)
        #expect(result == .zero)
    }

    @Test("负数输入被夹到零")
    func clampsNegativeInput() {
        #expect(PerfDuration.milliseconds(-5) == .zero)
    }
}

// MARK: - 行编解码

@Suite("JSONL 行编解码")
struct PerfRecordCodingTests {
    private func makeRecord(payload: some PerfPayload, severity: PerfSeverity = .warning) -> PerfAnyRecord {
        PerfAnyRecord(
            timestamp: Date(timeIntervalSince1970: 1_758_358_245.125),
            uptimeNanos: 81_234_567_890,
            sessionID: PerfSessionID(rawValue: "20260920T103045-A1B2C3"),
            severity: severity,
            thread: PerfThreadRef(isMain: true, machPort: 259, name: "main"),
            kind: type(of: payload).kind,
            schemaVersion: type(of: payload).schemaVersion,
            payload: payload
        )
    }

    @Test("信封与载荷编码后可完整还原")
    func roundTripsThroughJSONL() throws {
        let original = SampleMetric(value: 42.5, label: "cpu", counts: [1, 2, 3])
        let record = makeRecord(payload: original)

        let line = try JSONEncoder().encode(record)
        let envelope = try JSONDecoder().decode(PerfRawRecord.Envelope.self, from: line)
        let raw = PerfRawRecord(lineData: line, envelope: envelope)

        #expect(raw.kind == SampleMetric.kind)
        #expect(raw.schemaVersion == 3)
        #expect(raw.severity == .warning)
        #expect(raw.uptimeNanos == 81_234_567_890)
        #expect(raw.thread?.isMain == true)
        #expect(raw.thread?.machPort == 259)
        // 时间戳以 epoch 秒存储，比较时容忍浮点精度
        #expect(abs(raw.timestamp.timeIntervalSince1970 - 1_758_358_245.125) < 0.001)

        let decoded = try raw.decodePayload(as: SampleMetric.self)
        #expect(decoded == original)
    }

    @Test("用错误的载荷类型解码会被明确拒绝，而不是静默给出空值")
    func rejectsMismatchedPayloadType() throws {
        let record = makeRecord(payload: SampleMetric(value: 1, label: "x", counts: []))
        let line = try JSONEncoder().encode(record)
        let envelope = try JSONDecoder().decode(PerfRawRecord.Envelope.self, from: line)
        let raw = PerfRawRecord(lineData: line, envelope: envelope)

        #expect(throws: PerfRecordDecodingError.self) {
            _ = try raw.decodePayload(as: OtherMetric.self)
        }
    }

    @Test("落盘用短键名控制体积")
    func usesCompactKeys() throws {
        let record = makeRecord(payload: OtherMetric(flag: true))
        let line = try JSONEncoder().encode(record)
        let json = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])

        #expect(json.keys.sorted() == ["id", "k", "p", "s", "sev", "th", "ts", "up", "v"])
        #expect(json["k"] as? String == "sample.other")
        #expect(json["v"] as? Int == PerfAnyRecord.lineFormatVersion)
    }

    @Test("未携带线程信息时不写出该字段")
    func omitsAbsentThread() throws {
        let record = PerfAnyRecord(
            timestamp: Date(timeIntervalSince1970: 0),
            uptimeNanos: 0,
            sessionID: PerfSessionID(rawValue: "s"),
            severity: .info,
            thread: nil,
            kind: OtherMetric.kind,
            schemaVersion: OtherMetric.schemaVersion,
            payload: OtherMetric(flag: false)
        )
        let line = try JSONEncoder().encode(record)
        let json = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(json["th"] == nil)
    }
}

// MARK: - 栈签名

@Suite("栈签名")
struct PerfStackSignatureTests {
    private func frame(imageOffset: UInt64, address: UInt64) -> PerfFrame {
        PerfFrame(address: address, imageName: "App", imageOffset: imageOffset)
    }

    @Test("签名基于镜像偏移，绝对地址变化不影响结果")
    func signatureIsASLRStable() {
        // 同一段代码在两次启动中的绝对地址不同，但镜像偏移相同
        let run1 = [frame(imageOffset: 0x1000, address: 0x1_0000_1000),
                    frame(imageOffset: 0x2000, address: 0x1_0000_2000)]
        let run2 = [frame(imageOffset: 0x1000, address: 0x7_F000_1000),
                    frame(imageOffset: 0x2000, address: 0x7_F000_2000)]

        #expect(
            PerfThreadSnapshot.computeSignature(frames: run1)
                == PerfThreadSnapshot.computeSignature(frames: run2)
        )
    }

    @Test("不同调用栈产生不同签名")
    func differentStacksDiffer() {
        let a = [frame(imageOffset: 0x1000, address: 0x1000)]
        let b = [frame(imageOffset: 0x2000, address: 0x2000)]
        #expect(
            PerfThreadSnapshot.computeSignature(frames: a)
                != PerfThreadSnapshot.computeSignature(frames: b)
        )
    }

    @Test("帧顺序不同即视为不同调用栈")
    func orderMatters() {
        let a = [frame(imageOffset: 0x1000, address: 0), frame(imageOffset: 0x2000, address: 0)]
        let b = [frame(imageOffset: 0x2000, address: 0), frame(imageOffset: 0x1000, address: 0)]
        #expect(
            PerfThreadSnapshot.computeSignature(frames: a)
                != PerfThreadSnapshot.computeSignature(frames: b)
        )
    }
}
