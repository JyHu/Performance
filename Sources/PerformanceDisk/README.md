# PerformanceDisk

磁盘剩余空间、吞吐、主线程同步 I/O 监测。

## 职责

回答三个问题：磁盘还够不够写？进程在疯狂读写吗？主线程上有慢速的同步 I/O 吗？

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfDiskMonitor` | 监测器，配置见 `PerfDiskMonitorOptions` |
| `PerfDiskSpaceSample` | 总容量、可用容量、「重要用途」可用量 |
| `PerfDiskThroughputSample` | 读/写字节每秒（仅 macOS） |
| `PerfMainThreadIOEvent` | 主线程同步 I/O 的耗时与路径 |
| `PerfIOProbe` | 业务方主动包裹 I/O 的探针 |

## 用法

```swift
// 业务方在主线程做同步 I/O 时主动打点
PerfIOProbe.measure("write-blob", path: url.path, byteCount: payload.count) {
    try? payload.write(to: url)
}
```

## 关键设计

- **真正的 I/O 计量来自内核**：吞吐用 `proc_pid_rusage`，业务方任何直接调用都覆盖在内。上一版只在自封装的 API 里掐表，业务方用 `Data(contentsOf:)` 就统计不到。
- **iOS 上吞吐不可用**：`proc_pid_rusage` 未在 iOS SDK 公开声明，返回 `nil`，改由 `PerformanceMetricKit` 提供磁盘写入量。
- **探针只解决「是谁在做 I/O」**：内核计量回答总量，探针回答位置（哪一行、主线程、耗时）。两者互补。
- **主线程 I/O 阈值**：默认 8ms ≈ 一帧预算，超过意味着这次 I/O 至少吃掉一帧。路径经脱敏链处理。
