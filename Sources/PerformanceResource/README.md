# PerformanceResource

CPU / 内存 / 线程数 / 内核活动监测。

## 职责

周期性采样进程 CPU 占用率、内存足迹、线程数，按阈值定级。是定位「CPU 飙高」「内存泄漏」「线程失控」的第一手数据。

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfResourceMonitor` | 监测器（actor），配置见 `PerfResourceMonitorOptions` |
| `PerfCPUSample` | CPU 占用率 + 窗口时长 + Top 线程 + 线程数 |
| `PerfMemorySample` | 足迹 / 常驻 / 相对基线增长 / 可用内存 |
| `PerfKernelActivitySample` | 缺页换入、上下文切换差分 |

## 用法

```swift
var config = PerformanceConfiguration()
config.enable(PerfResourceMonitor.self) {
    $0.interval = .seconds(5)
    $0.recordsNormalSamples = false   // 只留超阈值的
}
```

## 关键设计

- **内存用足迹而非常驻**：`phys_footprint` 是 iOS jetsam 判定依据。常驻含共享页，系统性高估。
- **增长量单独成维度**：绝对值高不一定是问题（图片缓存本来就占内存），**持续增长**才是泄漏信号。
- **CPU 用相对窗口的占用率**：`usagePercent(since:elapsed:)` 由调用方差分，不同采样周期可比较。窗口时长一并落盘。
- **Top 线程只记前 N 个**：全记会让数据量膨胀数倍，排查真正需要的只有最忙的那几个。
- **内核活动低优先级**：上下文切换激增是锁竞争信号，但单独看无法定级，标 `.debug` 供对照。
