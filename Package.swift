// swift-tools-version: 6.2
// Performance —— iOS / macOS 性能统计框架
//
// 分层：
//   C 层      CPerfBacktrace / CPerfCrash          async-signal-safe 的栈回溯与崩溃捕获
//   基础层    PerformanceCore                      模型、协议、调度、平台抽象（无依赖）
//             PerformanceSystemKit                 mach / Darwin 系统原语的唯一封装
//             PerformanceBacktrace                 C 层的 Swift 封装
//             PerformanceStorage                   JSONL 分片持久化
//   采集层    11 个互不依赖的监测 target，只通过 PerfEventSink 协议出数据
//   中心层    Performance                          @_exported import 全部 + 编排

import PackageDescription

// MARK: - target 清单

let foundationTargets: [String] = [
    "PerformanceCore",
    "PerformanceSystemKit",
    "PerformanceBacktrace",
    "PerformanceStorage",
]

/// (target 名, 除 PerformanceCore 之外的额外依赖)
let collectors: [(name: String, extraDependencies: [Target.Dependency])] = [
    ("PerformanceResource",   ["PerformanceSystemKit"]),
    ("PerformanceDisk",       ["PerformanceSystemKit"]),
    ("PerformanceRendering",  []),
    ("PerformanceHang",       ["PerformanceBacktrace", "PerformanceSystemKit"]),
    ("PerformanceProfiler",   ["PerformanceBacktrace"]),
    ("PerformanceLaunch",     ["PerformanceSystemKit"]),
    ("PerformanceTrace",      []),
    ("PerformanceNetwork",    []),
    ("PerformanceCrash",      ["CPerfCrash", "PerformanceBacktrace"]),
    ("PerformancePower",      []),
    ("PerformanceMetricKit",  []),
]

let collectorNames: [String] = collectors.map { $0.name }

/// 对外可单独依赖的模块。基础层与采集层各自独立成 product，
/// 只想要 FPS 的业务方可以只依赖 PerformanceRendering，不必链接 crash handler 和 MetricKit。
let standaloneModules: [String] = foundationTargets + collectorNames

// MARK: - Products

var products: [Product] = [
    .library(name: "Performance", targets: ["Performance"]),   // 全家桶入口
    .executable(name: "PerfDemo", targets: ["PerfDemo"]),
]
for module in standaloneModules {
    products.append(.library(name: module, targets: [module]))
}

// MARK: - Targets

var targets: [Target] = []

// C 层
targets.append(
    .target(
        name: "CPerfBacktrace",
        cSettings: [.headerSearchPath("include")]
    )
)
targets.append(
    .target(
        name: "CPerfCrash",
        dependencies: ["CPerfBacktrace"],
        cSettings: [.headerSearchPath("include")]
    )
)
// 未被 Swift 模块化导出的系统 API 垫片（如 iOS 上的 proc_pid_rusage）
targets.append(
    .target(
        name: "CPerfSystem",
        cSettings: [.headerSearchPath("include")]
    )
)

// 基础层
targets.append(.target(name: "PerformanceCore"))
// SystemKit 依赖 CPerfBacktrace 只为复用「主线程端口登记」那一份唯一状态，
// 避免两处各存一份、两处都可能忘记登记。
targets.append(
    .target(
        name: "PerformanceSystemKit",
        dependencies: ["CPerfBacktrace", "CPerfSystem", "PerformanceCore"]
    )
)
targets.append(.target(name: "PerformanceBacktrace", dependencies: ["CPerfBacktrace", "PerformanceCore"]))
targets.append(.target(name: "PerformanceStorage", dependencies: ["PerformanceCore"]))

// 采集层
for collector in collectors {
    var dependencies: [Target.Dependency] = ["PerformanceCore"]
    dependencies.append(contentsOf: collector.extraDependencies)
    targets.append(.target(name: collector.name, dependencies: dependencies))
}

// 中心层
let umbrellaDependencies: [Target.Dependency] = standaloneModules.map { .target(name: $0) }
targets.append(.target(name: "Performance", dependencies: umbrellaDependencies))

// 可运行 Demo：主动制造各类性能问题，验证端到端链路
targets.append(
    .executableTarget(
        name: "PerfDemo",
        dependencies: ["Performance"],
        path: "Examples/PerfDemo"
    )
)

// 测试
let monitorTestDependencies: [Target.Dependency] = {
    var deps: [Target.Dependency] = ["PerformanceCore"]
    deps.append(contentsOf: collectorNames.map { Target.Dependency.target(name: $0) })
    return deps
}()

targets.append(.testTarget(name: "PerformanceCoreTests", dependencies: ["PerformanceCore"]))
targets.append(.testTarget(name: "PerformanceStorageTests", dependencies: ["PerformanceStorage", "PerformanceCore"]))
targets.append(.testTarget(name: "PerformanceBacktraceTests", dependencies: ["PerformanceBacktrace"]))
targets.append(.testTarget(name: "PerformanceSystemKitTests", dependencies: ["PerformanceSystemKit", "PerformanceCore"]))
targets.append(.testTarget(name: "PerformanceMonitorTests", dependencies: monitorTestDependencies))
targets.append(.testTarget(name: "PerformanceIntegrationTests", dependencies: ["Performance"]))

// MARK: - Package

let package = Package(
    name: "Performance",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: products,
    targets: targets
)
