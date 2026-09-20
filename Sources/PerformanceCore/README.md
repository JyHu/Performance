# PerformanceCore

框架的核心层：数据模型、监测器协议、运行时设施、配置系统、平台抽象、导出契约。

## 职责

不采集任何数据，不碰任何系统 API——它只定义「采集到的数据长什么样」「监测器怎么写」「数据往哪儿走」。所有监测器都依赖这一层，但本层不依赖任何其他 target。

## 主要类型

| 类别 | 类型 |
|---|---|
| 数据模型 | `PerfPayload`（类型安全载荷协议）、`PerfRecord`、`PerfAnyRecord`（类型擦除）、`PerfRawRecord`、`PerfKind`、`PerfSeverity`、`PerfDuration`、`PerfSessionID`、`PerfThreadRef` |
| 监测器协议 | `PerfMonitor`、`PerfMonitorOptions`、`PerfMonitorDescriptor`、`PerfMonitorID`、`PerfMonitorContext`、`PerfMonitorRegistration`、`PerfAnyMonitor` |
| 数据通路 | `PerfEventSink`、`PerfBufferSink`、`PerfNullSink`、`PerfCollectingSink`、`PerfRecorder`、`PerfRecordBuffer` |
| 调度与时钟 | `PerfScheduler`、`PerfManualScheduler`、`PerfScheduling`、`PerfTick`、`PerfCadenceToken`、`PerfClock`、`PerfSystemClock`、`PerfManualClock` |
| 配置 | `PerfConfiguration`、`PerfStorageOptions`、`PerfPipelineOptions`、`PerfOptionsBox` |
| 平台抽象 | `PerfAppLifecycle`、`PerfAppLifecycleEvent`、`PerfDisplayLinkDriver`、`PerfFrameTick` |
| 导出契约 | `PerfExporter`、`PerfConsoleExporter`、`PerfClosureExporter`、`PerfRecordBatch` |
| 脱敏 | `PerfRedactionPolicy`、`PerfRedactable`、`PerfRedactablePayload` |
| 基础设施 | `PerfLock`、`PerfLog`、`PerfPlatformSupport` |

## 关键设计

- **类型安全数据模型**：载荷实现 `PerfPayload` 协议，字段强类型。取代上一版 `[String: String]` 万能袋——那种设计让写入方写 `"cpu_percent"`、读取方读 `"cpuUsage"` 这类错误完全绕过编译器。
- **监测器是 actor**：`PerfMonitor` 协议要求 actor 实现，状态由编译器保证隔离。依赖全部经 `PerfMonitorContext` 注入（数据出口、调度器、时钟、日志、栈回溯、生命周期），**没有单例**。
- **采集侧永不阻塞**：`PerfRecordBuffer` 临界区内无内存分配、无 I/O。采集点（可能在主线程 RunLoop / DisplayLink 回调）只做 O(1) 入队，编码/脱敏/写盘全部发生在后台。
- **可测试**：`PerfManualClock` + `PerfManualScheduler` 让「模拟 30 秒采样」变成 300 次同步调用，不需要 `Thread.sleep`。
- **平台差异收敛**：生命周期、显示链路在 `Platform/` 下统一，监测器只面对一个抽象。
