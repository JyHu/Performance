# PerformanceMetricKit

MetricKit 桥接：系统级聚合指标与诊断。

## 职责

接收系统每日投递一次的 `MXMetricPayload`（启动耗时、挂起率、CPU、内存、磁盘写入量）和 `MXDiagnosticPayload`（崩溃、卡顿、磁盘异常、CPU 异常），转成本框架的记录。

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfMetricKitMonitor` | 监测器，配置见 `PerfMetricKitMonitorOptions` |
| `PerfMetricKitPayload` | 聚合指标：覆盖区间、各指标中位数、原始 JSON |
| `PerfMetricKitDiagnostic` | 诊断：category（crash/hang/…）、原始 JSON（含系统符号化调用树） |

## 关键设计

- **与自采数据互补，不是替代**：MetricKit 优势是系统视角、零运行时开销、崩溃栈已符号化、覆盖全体用户；局限是最长滞后 24 小时、只有聚合值、拿不到业务上下文。自采数据用来定位具体问题，MetricKit 给出可信的大盘基线。
- **时间戳取覆盖区间开始**：数据最多滞后 24 小时，按收到的时刻落盘会把数据放到时间线错误的位置。
- **崩溃栈已符号化**：诊断 JSON 里系统侧做了符号化，不需要上传 dSYM、不需要自己还原——这是相对自采崩溃捕获的一大优势。
- **原始 JSON 可关**：有几十 KB，但含符号化调用树，默认保留。
- **iOS 限定**：MetricKit 在 macOS 12+ 可用但仅在部分场景投递，iOS 上是主力。
