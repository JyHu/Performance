# Performance

iOS / macOS 应用性能统计与排查框架。零三方依赖，Swift 6 严格并发，数据本地 JSONL 持久化。

```swift
import Performance

try await PerfCenter.shared.bootstrap(.production)
```

- **最低版本**：iOS 15 / macOS 12
- **依赖**：无。仅使用系统框架
- **网络**：框架自身零网络依赖，上报由业务方实现并注入

---

## 快速开始

### 接入

```swift
import Performance

// 1. 尽早在 main() 里打一个点，让启动统计能覆盖到最前面
PerfLaunchTimeline.shared.mark(PerfLaunchTimeline.Mark.main)

// 2. 启动框架
try await PerfCenter.shared.bootstrap(.production)

// 3. 首屏出现时标记（可选，但能显著提高启动数据的准确度）
PerfLaunchTimeline.markFirstFrame()
```

### 业务打点

```swift
// 同步
let config = PerfTrace.measure("load-config") {
    ConfigLoader.load()
}

// 异步，嵌套关系自动建立
await PerfTrace.measure("page-load") {
    await PerfTrace.measure("fetch") { try await api.fetch() }
    PerfTrace.measureLayout("layout") { view.layoutIfNeeded() }
}

// 显式配对
let token = PerfTrace.begin("upload")
// ...
PerfTrace.end(token, attributes: ["size": "\(bytes)"])
```

框架未启动时这些调用全部退化为空操作，`body` 照常执行，业务方无需判空。

### 网络观测

```swift
// 方式一：用框架提供的 session
let session = PerfNetworkObserver.makeSession()

// 方式二：在自己的 delegate 里转发一行
func urlSession(_ s: URLSession, task: URLSessionTask,
                didFinishCollecting metrics: URLSessionTaskMetrics) {
    PerfNetworkObserver.observe(metrics: metrics, task: task)
}
```

刻意**不**提供全局 `URLProtocol` 注入——那会改变所有请求的执行路径，可能影响上传、WebSocket、后台会话，性能监控不该有这种侵入性。

### 导出数据

```swift
// 打包成单个 gzip 压缩的 JSONL，可直接附到 bug 单
let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf.jsonl.gz")
try await PerfCenter.shared.exportArchive(to: url)
```

接收方用 `zcat perf.jsonl.gz | grep hang.anr` 就能看，不需要任何专用工具。

### 上报

框架只定义契约，不含具体实现：

```swift
struct MyExporter: PerfExporter {
    let identifier = "company.telemetry"
    func export(_ batch: PerfRecordBatch) async throws {
        // 你的 endpoint、鉴权、采样、重试策略
    }
}

await PerfCenter.shared.addExporter(MyExporter())
```

上报涉及的每件事都是业务决策：打到哪、怎么鉴权、采样率多少、失败重试几次、是否只在 Wi-Fi 下传、数据合不合规。框架替业务方做这些决定只会带来麻烦。

---

## 预设

| 预设 | 用途 | 取舍 |
|---|---|---|
| `.production` | 线上 | 只留能直接指向问题的数据，关掉高频常规采样；脱敏为 `.strict`（不落符号名）；配额 30MB |
| `.debug` | 开发调试 | 全量采集、不脱敏、不压缩（方便 `tail`/`grep`）；配额 200MB |
| `.diagnostic` | 复现特定问题时临时开启 | 10ms 热点采样、50ms 卡顿阈值。**开销明显**，不适合长期运行 |
| `.minimal` | 只要崩溃和卡顿 | 两个监测器，配额 10MB |

预设可以继续改：

```swift
var config = PerfConfiguration.production
config.enable(PerfHangMonitor.self) { $0.unresponsiveThreshold = .seconds(3) }
config.storage.totalQuota = .megabytes(50)
try await PerfCenter.shared.bootstrap(config)
```

---

## 架构

```
                      ┌──────────────────────────┐
                      │       Performance        │  中心 target（全家桶）
                      │  @_exported import ×15   │  + PerfCenter 编排
                      └────────────┬─────────────┘
       ┌───────────────────────────┼───────────────────────────┐
       ▼                           ▼                           ▼
┌──────────────┐          ┌─────────────────┐        ┌──────────────────┐
│  采集层 ×11  │          │ PerfStorage │      │ 每个模块独立成   │
│ 互不依赖     │──sink──▶ │   JSONL 分片      │       │ product，可按需  │
└──────┬───────┘          └─────────────────┘        │ 单独依赖         │
       │                                              └──────────────────┘
       ▼
┌────────────────┬──────────────────────┬─────────────────────┐
│ PerformanceCore│ PerfSystemKit │ PerfBacktrace│  基础层
└────────────────┴──────────────────────┴──────────┬──────────┘
                                                    ▼
                                    ┌───────────────────────────┐
                                    │ CPerfBacktrace / CPerfCrash│  C 层
                                    │ CPerfSystem                │
                                    └───────────────────────────┘
```

### 采集层

每个 target 只依赖 `PerformanceCore`，**不依赖存储层**，只通过 `PerfEventSink` 协议出数据。换持久化方案不需要改任何一个采集器。

| Target | 覆盖 | 核心机制 |
|---|---|---|
| `PerfResource` | CPU / 内存 / 线程数 / 缺页 / 上下文切换 | `TASK_ABSOLUTETIME_INFO`、`TASK_VM_INFO.phys_footprint` |
| `PerfHang` | ANR / 死锁 / RunLoop 卡顿 / 阶段分解 / 主队列时延 | 一个 RunLoop observer + 一个 watchdog |
| `PerfRendering` | FPS / Jank / 卡顿时间占比 | `CADisplayLink`（iOS / macOS 14+）、`CVDisplayLink`（macOS 12–13） |
| `PerfProfiler` | 热点方法 Top-N | 独立线程挂起目标线程取栈 |
| `PerfLaunch` | pre-main / 冷启动 / 热启动 / 自定义阶段 | `sysctl(KERN_PROC)` 取进程创建时间 |
| `PerfTrace` | Span / 页面 / 布局 / 业务链路 | 统一 Span 模型 + `os_signpost` |
| `PerfNetwork` | DNS / connect / TLS / TTFB / P95 / 超时率 | `URLSessionTaskMetrics` |
| `PerfCrash` | signal / mach exception / NSException | async-signal-safe 的 C 层 |
| `PerfDisk` | 剩余空间 / 吞吐 / 主线程同步 I/O | 内核 rusage + 主动探针 |
| `PerfPower` | 电量 / 热状态 / 低电量模式 | `ProcessInfo.thermalState` |
| `PerfMetricKit` | 系统级聚合指标与诊断 | `MXMetricManager` |

### 按需链接

每个模块都是独立 product。只想要 FPS 的话：

```swift
.product(name: "PerfRendering", package: "Performance")
```

不会被迫链接 crash handler 和 MetricKit。

### 模块目录

每个 target 有独立 README：

| 层 | 模块 | 职责 |
|---|---|---|
| 中心 | [Sources/Performance](Sources/Performance/README.md) | `@_exported import` 全部 + `PerfCenter` 编排 + 预设 |
| 基础 | [PerformanceCore](Sources/PerformanceCore/README.md) | 数据模型、监测器协议、调度、平台抽象 |
| 基础 | [PerformanceSystemKit](Sources/PerformanceSystemKit/README.md) | CPU / 内存 / 磁盘 / 进程系统原语 |
| 基础 | [PerformanceBacktrace](Sources/PerformanceBacktrace/README.md) | 跨线程栈回溯、栈签名、镜像清单 |
| 基础 | [PerformanceStorage](Sources/PerformanceStorage/README.md) | JSONL 分片持久化、查询、归档、清理 |
| 采集 | [PerformanceResource](Sources/PerformanceResource/README.md) | CPU / 内存 / 线程数 / 内核活动 |
| 采集 | [PerformanceHang](Sources/PerformanceHang/README.md) | ANR / 死锁 / RunLoop 卡顿 / 主队列时延 |
| 采集 | [PerformanceRendering](Sources/PerformanceRendering/README.md) | FPS / Jank / 卡顿时间占比 |
| 采集 | [PerformanceProfiler](Sources/PerformanceProfiler/README.md) | 热点方法采样 |
| 采集 | [PerformanceLaunch](Sources/PerformanceLaunch/README.md) | pre-main / 冷启动 / 热启动 / 自定义阶段 |
| 采集 | [PerformanceTrace](Sources/PerformanceTrace/README.md) | 业务打点 Span / 页面 / 布局 |
| 采集 | [PerformanceNetwork](Sources/PerformanceNetwork/README.md) | DNS / connect / TLS / TTFB / P95 / 超时率 |
| 采集 | [PerformanceCrash](Sources/PerformanceCrash/README.md) | signal / mach exception / NSException |
| 采集 | [PerformanceDisk](Sources/PerformanceDisk/README.md) | 剩余空间 / 吞吐 / 主线程同步 I/O |
| 采集 | [PerformancePower](Sources/PerformancePower/README.md) | 电量 / 热状态 / 低电量模式 |
| 采集 | [PerformanceMetricKit](Sources/PerformanceMetricKit/README.md) | MetricKit 系统级聚合指标与诊断 |

---

## 几个关键设计

### 卡顿检测不向主队列投递任何东西

常见做法是后台定时往主队列扔信号量、测它多久被处理。这里反过来：主线程的 RunLoop observer 被唤醒时记一个时间戳、休眠时清掉，watchdog 只**读**这个值。

三个实质好处：

- 主线程零额外负担，不会出现「检测卡顿的探针自己加剧了卡顿」
- 卡顿**还在进行时**就能发现，因而抓到的是真正的现场堆栈；投递式探针只能在主线程恢复后才知道刚才卡过，那时堆栈已经无关
- 主队列积压严重时，投递式探针自己也会排队，测出的时间是失真的

### 死锁判据是寄存器，不是耗时

跑得慢的代码 PC 会持续变化，真卡死的不会。只看耗时无法区分「死锁」和「在算一个很大的循环」。

### 采集侧永不阻塞

```
采集点（可能在主线程 RunLoop / DisplayLink 回调）
   │  ① O(1) 无阻塞入队，缓冲满则丢弃并计数
   ▼
PerfRecordBuffer（有界、加锁、临界区内无内存分配）
   │  ② 后台 actor 按 N 条或 T 秒批量取走
   ▼
PerfStoragePipeline（脱敏 → JSON 编码 → 落盘 → 导出器）
```

编码、脱敏、写盘、压缩全部发生在采集点之外。丢弃量本身作为 `core.dropped` 指标落盘——数据缺口不能被误读成「这段时间没问题」。

### 数据是类型安全的

```swift
public struct PerfCPUSample: PerfPayload {
    public static let kind: PerfKind = "resource.cpu"
    public let processPercent: Double
    public let windowMs: Double
    public let topThreads: [PerfThreadUsage]
}
```

不用 `[String: String]` 装异构数据。那种设计会让写入方写 `"cpu_percent"`、读取方读 `"cpuUsage"` 这类错误完全绕过编译器，只能在运行时表现为「某个判断永远不成立」。

### 查询结果自述完整性

```swift
let result = await PerfCenter.shared.records(matching: filter)
result.isComplete          // 有跳过的坏行或读不出的分片时为 false
result.skippedLineCount
result.truncatedShards     // 进程被杀留下的半行
```

基于残缺数据得出的性能结论比没有结论更危险。

---

## 持久化

```
<Caches>/Performance/
├── sessions/
│   ├── 20260920T103045-A1B2C3/
│   │   ├── manifest.json          设备 / OS / app 版本 / 启停时间
│   │   ├── hang-000.jsonl         按 kind 大类分片
│   │   ├── hang-001.jsonl         超过 2MB 滚动
│   │   └── resource-000.jsonl.gz  非当前分片自动 gzip 归档
│   └── 20260919T221130-D4E5F6/
└── crash/
    └── pending.crash              崩溃现场裸报告，下次启动解析
```

每行一条独立 JSON，短键名控制体积：

```json
{"v":1,"k":"hang.anr","s":1,"id":"...","ts":1758358245.125,"up":81234567890,"sev":"critical","th":{"isMain":true},"p":{"stage":"unresponsive","durationMs":2130,...}}
```

| 维度 | 策略 |
|---|---|
| 写入 | POSIX `write(2)` append-only，批量攒够条数或时间写一次 |
| 崩溃安全 | 进程被杀最多损失最后一行；读取侧跳过坏行并计数，不中断 |
| 滚动 | 单片超 2MB 新开分片；跨天新开 session |
| 配额 | 默认总量 50MB，超限从最旧 session 整体删除；**当前 session 永不删** |
| 保留 | 常规数据 7 天，崩溃报告 30 天 |
| 压缩 | 非当前分片 gzip（真 gzip 容器，可 `gunzip`） |
| 脱敏 | 写盘前应用；失败时 fail-closed，宁可丢数据也不放出未处理内容 |
| 查询 | 按 kind 大类分文件 + session 目录名带时间戳，类型与时间范围过滤可整片跳过 |

`manifest.json` 里 `endedAt` 为 `nil` 表示进程是被杀掉的——崩溃、OOM、看门狗终止都会留下这个痕迹。

---

## Demo

```bash
swift run PerfDemo            # 全部场景 + 开销对照
swift run PerfDemo overhead   # 只跑开销对照
```

会主动制造 CPU 占用、内存增长、主线程同步 I/O、嵌套打点，然后打印采集结果、框架自身健康度，并把同一段工作在「监控全开」与「全关」下各跑一遍做开销对照。

---

## 测试

```bash
swift test                                              # macOS
xcodebuild -scheme Performance -destination 'generic/platform=iOS' build   # iOS
```

201 个用例。全部使用注入的 `PerfManualClock` / `PerfManualScheduler` / `PerfCollectingSink`，**没有任何 `Thread.sleep`**——「模拟 30 秒采样」是 300 次同步调用而不是真的等 30 秒。

重点覆盖：

- **跨线程栈回溯正确性**：起一个调用链已知的后台线程，从另一个线程抓它的栈，断言符号与顺序
- **存储容错**：分片滚动边界、配额驱逐、进程被 kill 后的截断行恢复、并发写、过期清理
- **卡顿判定**：每级只报一次、时间戳取开始时刻、寄存器冻结 → 死锁 vs 寄存器变化 → 只是慢
- **gzip 容器**：CRC 校验、标准格式、损坏时拒绝返回半截数据

---

## 平台差异

框架在两端行为一致，除了以下几处系统能力本身的差异：

| 能力 | iOS | macOS |
|---|---|---|
| 进程磁盘 I/O 字节数 | **不可用**（`proc_pid_rusage` 未公开声明，用它等于私有 API）。改由 MetricKit 提供 | 可用 |
| 帧回调 | `CADisplayLink`，回调在**主线程** | macOS 14+ `CADisplayLink`；12–13 `CVDisplayLink`，回调在**专用线程** |
| 前后台切换 / 内存告警 | 有 | 无对应概念 |
| MetricKit 投递 | 每日一次 | 仅部分场景 |

不可用的能力**返回 `nil` 并标记，不返回 0**——返回 0 会被误读成「测到了，值是零」。

---

## 已知取舍

- **`@unchecked Sendable` 共 24 处**（`nonisolated(unsafe)` 为零）。全部集中在一类场景：必须提供**同步** API 的类型。它们被 C 回调（`CFRunLoopObserver`、`CVDisplayLink`、signal handler）或业务代码从任意线程直接调用，那些位置既不能 `await`，也不能承受 actor 跳转的开销——所以无法做成 actor。

  每一处都满足下面两条之一：
  - **受 `PerfLock` 保护**（22 处）：缓冲、累加器、配置盒、各类驱动与追踪器
  - **构造后完全不可变**（2 处）：`PerfLock` 自身是锁原语；`MetricKitSubscriber` 的存储属性全是 `Sendable` 的 `let`

  监测器本身**一律是 actor**，没有例外。
- **两个进程级入口**：`PerfTrace` 和 `PerfLaunchTimeline`。业务代码要从任意位置调用它们，不可能要求每个调用点先拿到 `PerfMonitorContext`；而启动计时中的某些时刻发生在框架被配置之前。两者都只存值、无行为，监测器停止后退化为空操作。
- **首帧是代理指标**：iOS 没有公开的「首帧渲染完成」通知。框架用「app 激活后首次主 RunLoop 空闲」近似，略晚于真实首帧。业务方调用 `markFirstFrame()` 可得到准确值，数据里会标明来源（`explicit` / `runLoopIdleApproximation`）。
- **崩溃报告里的镜像清单**：`_dyld_*` 系列严格说不是 async-signal-safe。崩溃时 dyld 锁被持有的概率很低，而缺了镜像清单整份报告就无法符号化——这是一个明确的取舍。
