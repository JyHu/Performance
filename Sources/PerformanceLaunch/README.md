# PerformanceLaunch

启动耗时监测：pre-main / 冷启动 / 热启动 / 自定义阶段。

## 职责

从进程创建（内核）到首帧（或其代理），分解冷启动各阶段耗时；热启动记录回到前台到可交互的耗时。

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfLaunchMonitor` | 监测器，配置见 `PerfLaunchMonitorOptions` |
| `PerfColdLaunchSample` | 冷启动分解：pre-main、didFinishLaunching、frameworkReady、首帧来源 |
| `PerfWarmLaunchSample` | 热启动：总耗时、后台停留时长 |
| `PerfLaunchStageSample` | 业务自定义启动阶段 |
| `PerfLaunchTimeline` | 进程级时间线，记录各关键时刻 |

## 用法

```swift
// main() 里尽早打点——让启动统计覆盖到最前面
PerfLaunchTimeline.shared.mark(PerfLaunchTimeline.Mark.main)

// 首屏出现时标记（可选，显著提高准确度）
PerfLaunchTimeline.markFirstFrame()
```

## 关键设计

- **冷启动起点是进程创建时刻**：`sysctl(KERN_PROC)` 取内核记录的 `p_starttime`。上一版用 `ProcessInfo.systemUptime`（设备开机时长）当起点，算出的「冷启动耗时」实际是设备已运行时间。
- **首帧是代理指标**：iOS 没有公开的「首帧渲染完成」通知。框架用「app 激活后首次主 RunLoop 空闲」近似，略晚于真实首帧。业务方调 `markFirstFrame()` 得到准确值，数据里标明来源（`explicit` / `runLoopIdleApproximation`）。
- **frameworkReadyMs 决定可信度**：框架起得越晚，启动前期就有越长一段没被观测到。如实上报这个字段，免得把「没测到」误读成「没耗时」。
- **进程级时间线**：某些关键时刻发生在框架配置之前，`PerfLaunchTimeline` 只记时间戳、无行为，业务方可在 `main()` 第一行打点。
- **冷启动只报一次**：热启动（回到前台）不会覆盖冷启动数据。
