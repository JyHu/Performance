# PerformanceTrace

业务打点：Span / 页面耗时 / 布局耗时 / 业务链路。

## 职责

给业务代码一个统一的计时 API：同步/异步、可嵌套、带属性，可选发 `os_signpost` 给 Instruments。框架未启动时全部退化为空操作。

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfTrace` | 全局入口：`begin/end`、`measure`、`measurePage`、`measureLayout` |
| `PerfTracer` | 实际打点执行者 |
| `PerfSpanSample` | 结果：名称、分类、耗时、父级、深度、属性 |
| `PerfSpanToken` | 进行中的 span（值类型，不可变） |
| `PerfSpanCategory` | `.span` / `.page` / `.layout` |
| `PerfTraceMonitor` | 监测器，负责装上/拔掉 tracer |

## 用法

```swift
// 同步，未启用时直接执行 body，零开销
let config = PerfTrace.measure("load-config") { ConfigLoader.load() }

// 异步，嵌套关系经 task-local 自动建立
await PerfTrace.measure("page-load") {
    await PerfTrace.measure("fetch") { try await api.fetch() }
    PerfTrace.measureLayout("layout") { view.layoutIfNeeded() }
}

// 显式配对
let token = PerfTrace.begin("upload")
PerfTrace.end(token, attributes: ["size": "\(bytes)"])
```

## 关键设计

- **一套实现取代四套**：上一版把打点做成四套互不相干的 API（`traceBegin/End`、`PMIOTracker`、`PMLayoutRenderTracker`、`PMBusinessTracker`），每套都自己写一遍 `Double(end - start) / 1_000_000.0`。这里只有一处。
- **同步异步都走 task-local 嵌套**：内层闭包没有 `await` 时会匹配到同步重载，若不嵌套则「是否嵌套」取决于碰巧有没有 await，行为不可预期。两个重载行为一致。
- **抛错路径也结算**：`measure` 的 body 抛错时标记 `wasAbandoned` 并结算，不留悬空的开始。
- **时间戳取开始时刻**：5 秒的 span 若按结束时刻落盘，与同期 CPU/内存采样错位 5 秒。
- **进程级入口**：业务代码从任意位置调用，`PerfTrace` 只存 tracer 值；监测器停掉后打点退化为空操作。
- **可选 os_signpost**：Instruments 里直接看到时间线，与落盘数据两条路互不依赖。
