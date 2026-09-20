//
//  Performance.swift
//  中心 target：一次 `import Performance` 即可使用全部能力。
//
//  注意属性名是 `@_exported`（单下划线）。
//

// 基础层
@_exported import PerformanceCore
@_exported import PerformanceSystemKit
@_exported import PerformanceBacktrace
@_exported import PerformanceStorage
// 采集层
@_exported import PerformanceResource
@_exported import PerformanceDisk
@_exported import PerformanceRendering
@_exported import PerformanceHang
@_exported import PerformanceProfiler
@_exported import PerformanceLaunch
@_exported import PerformanceTrace
@_exported import PerformanceNetwork
@_exported import PerformanceCrash
@_exported import PerformancePower
@_exported import PerformanceMetricKit