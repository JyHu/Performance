# PerformanceRendering

FPS / Jank / 掉帧监测。

## 职责

通过屏幕刷新回调统计帧率，识别掉帧，并计算卡顿时间占比。

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfRenderingMonitor` | 监测器，配置见 `PerfRenderingMonitorOptions` |
| `PerfFPSSample` | 窗口聚合：FPS、目标 FPS、掉帧数、卡顿占比 |
| `PerfJankEvent` | 单次掉帧：帧耗时、丢帧数 |
| `PerfDisplayLinkFactory` | 创建平台对应的帧回调驱动 |
| `PerfDisplayLinkDriver` | 帧回调源协议（定义在 Core） |

## 关键设计

- **目标帧率跟随屏幕**：用 `targetTimestamp - timestamp` 而非假定 60Hz。ProMotion 设备 10~120Hz 动态变化，上一版把目标帧率当常量，在 120Hz 设备上把正常帧误判成掉帧。
- **平台差异收敛**：iOS `CADisplayLink`（主线程回调）、macOS 14+ `CADisplayLink`、macOS 12–13 `CVDisplayLink`（专用线程回调）。差异全部在 `PerfDisplayLinkFactory` 内部。
- **相对目标定级**：平均帧率用「相对目标帧率的比例」而非绝对值——120Hz 屏上 50fps 是严重问题，60Hz 屏上 50fps 尚可。
- **卡顿时间占比**：`hitchTimeRatio` = 超时多花的时间 / 窗口时长。60 帧里 1 帧卡 500ms，FPS 看起来还有 58，但用户明确感觉到顿挫。
- **掉帧事件限流**：滚动时掉帧可能极密集，单窗口最多记 N 条，其余只计入聚合，避免灌满缓冲。
- **回调只做 O(1) 累加**：帧回调在主线程，里面不做 I/O、不编码、不等待。
