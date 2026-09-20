# Performance（中心 target）

一次 `import Performance` 即可使用全部能力。这是框架对外唯一的入口模块。

## 职责

- `@_exported import` 全部基础层与采集层模块，业务方只需 `import Performance`
- `PerfCenter` 编排：根据配置构造、启动、停止所有监测器
- 预设配置：`.production` / `.debug` / `.diagnostic` / `.minimal`

## 用法

```swift
import Performance

// 启动（推荐用预设）
try await PerfCenter.shared.bootstrap(.production)

// 自定义配置
var config = PerformanceConfiguration.production
config.enable(PerfHangMonitor.self) { $0.unresponsiveThreshold = .seconds(3) }
try await PerfCenter.shared.bootstrap(config)
```

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfCenter` | 编排入口：bootstrap / shutdown / records / exportArchive / addExporter |
| `PerfConfiguration` | 完整配置 + 四个预设 |
| `PerfHealthSnapshot` | 实时健康快照：活跃监测器、内存、丢弃、采样跳过 |

## `PerfCenter` API

```swift
bootstrap(_:)          // 启动，返回配置自检告警
shutdown()             // 停止全部监测并落盘
records(matching:)     // 查询已落盘记录
exportArchive(to:)     // 打包 gzip 归档，可直接附 bug 单
addExporter(_:)        // 注入上报实现（框架零网络依赖）
healthSnapshot()       // 实时健康快照
diskUsage()            // 当前磁盘占用
```

## 关键设计

- **编排与监测逻辑分离**：`PerfCenter` 只遍历配置里的注册项。新增监测器实现 `PerfMonitor` 协议并在配置里 `enable`，**这个文件不用改**。上一版的门面是一段 96 行 `if config.enableX { ... }` 流水账，加一个监测项要改四处。
- **主线程端口尽早登记**：bootstrap 在 `MainActor` 上登记主线程端口，之后「抓主线程栈」「判断是否主线程」都依赖它。没登记会静默失效。
- **启动即清理**：启动时先清一次历史 session，避免遗留数据占满配额。
- **一个监测器失败不拖垮其他**：启动失败只记日志，其余照常运行。
