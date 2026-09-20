# PerformanceNetwork

网络性能监测：DNS / connect / TLS / TTFB / total / 超时率 / P95。

## 职责

把 `URLSessionTaskMetrics` 转成记录，按阶段分解耗时，维护滑动窗口内的成功率与超时率。

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfNetworkMonitor` | 监测器，配置见 `PerfNetworkMonitorOptions` |
| `PerfNetworkObserver` | 接入点：`makeSession()` 或转发 `observe(metrics:task:)` |
| `PerfNetworkRequestSample` | 单次请求阶段分解（URL 已脱敏） |
| `PerfNetworkFailureSample` | 失败：domain / code / 是否超时 |
| `PerfNetworkHealthSample` | 窗口聚合：成功率、超时率、中位数、P95 |

## 用法

```swift
// 方式一：用框架提供的 session（记得用完 invalidateAndCancel）
let session = PerfNetworkObserver.makeSession()

// 方式二：在自己的 delegate 里转发一行
func urlSession(_ s: URLSession, task: URLSessionTask,
                didFinishCollecting metrics: URLSessionTaskMetrics) {
    PerfNetworkObserver.observe(metrics: metrics, task: task)
}
```

## 关键设计

- **刻意不做全局 URLProtocol 注入**：那会改变所有请求的执行路径，可能影响上传、WebSocket、后台会话——性能监控不该有这种侵入性。
- **分阶段耗时**：DNS 慢查解析配置、TLS 慢查握手、TTFB 慢是服务端问题、传输慢是带宽/响应体问题。优化方向完全不同。
- **缓存命中的请求排除在统计外**：混进去会把平均值拉得很好看，掩盖真实网络状况。
- **用 P95 而非平均值**：平均值被大量快请求稀释，真正影响体感的是尾部延迟。
- **`makeSession` 的 delegate 泄漏问题已修**：上一版每次调用都 new 一个 delegate 且从不 invalidate。现在 session 强持有 delegate，调用方负责 `invalidateAndCancel`。
