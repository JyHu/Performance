import Foundation
import PerformanceCore
import PerformanceCrash
import PerformanceDisk
import PerformanceHang
import PerformanceLaunch
import PerformanceMetricKit
import PerformanceNetwork
import PerformancePower
import PerformanceProfiler
import PerformanceRendering
import PerformanceResource
import PerformanceTrace

extension PerfConfiguration {
    /// 生产环境预设。
    ///
    /// 取舍：只保留能直接指向问题的数据，关掉高频的常规采样。
    /// 性能框架自己的开销必须小到可以忽略，否则它就成了要排查的对象。
    public static var production: PerfConfiguration {
        var config = PerfConfiguration()
        config.isLoggingEnabled = false
        config.redaction = .strict
        config.pipeline.minimumSeverity = .info
        config.storage.totalQuota = .megabytes(30)
        config.storage.retention = .days(7)

        config.enable(PerfResourceMonitor.self) {
            $0.interval = .seconds(5)
            // 只留超阈值的；常规采样在生产环境量太大
            $0.recordsNormalSamples = false
            $0.tracksKernelActivity = false
        }
        config.enable(PerfHangMonitor.self) {
            $0.hitchThreshold = .milliseconds(500)
            $0.tracksRunLoopPhases = false
        }
        config.enable(PerfRenderingMonitor.self) {
            $0.recordsNormalSamples = false
            $0.recordsIndividualJank = false    // 只保留窗口聚合
        }
        config.enable(PerfLaunchMonitor.self)
        config.enable(PerfTraceMonitor.self)
        config.enable(PerfNetworkMonitor.self) {
            $0.recordsIndividualRequests = false
        }
        config.enable(PerfCrashMonitor.self)
        config.enable(PerfPowerMonitor.self)
        config.enable(PerfMetricKitMonitor.self)
        config.enable(PerfDiskMonitor.self)
        return config
    }

    /// 开发调试预设。
    ///
    /// 与生产相反：尽可能多留上下文，开销让位于可观测性。
    public static var debug: PerfConfiguration {
        var config = PerfConfiguration()
        config.isLoggingEnabled = true
        config.redaction = .disabled
        config.pipeline.minimumSeverity = .debug
        config.storage.totalQuota = .megabytes(200)
        config.storage.compressArchivedShards = false   // 方便直接 tail/grep

        config.enable(PerfResourceMonitor.self) { $0.interval = .seconds(1) }
        config.enable(PerfHangMonitor.self) {
            $0.hitchThreshold = .milliseconds(100)
            $0.tracksRunLoopPhases = true
        }
        config.enable(PerfRenderingMonitor.self)
        config.enable(PerfProfilerMonitor.self)
        config.enable(PerfLaunchMonitor.self)
        config.enable(PerfTraceMonitor.self)
        config.enable(PerfNetworkMonitor.self)
        config.enable(PerfCrashMonitor.self)
        config.enable(PerfPowerMonitor.self)
        config.enable(PerfDiskMonitor.self)
        config.enable(PerfMetricKitMonitor.self)
        return config
    }

    /// 深度诊断预设。
    ///
    /// 用于复现特定问题时临时开启。**开销明显**，不适合长期运行：
    /// 10ms 的热点采样意味着每秒挂起主线程 100 次。
    public static var diagnostic: PerfConfiguration {
        var config = PerfConfiguration.debug
        config.baseSamplingInterval = .milliseconds(50)
        config.pipeline.bufferCapacity = 16_384

        config.enable(PerfResourceMonitor.self) {
            $0.interval = .milliseconds(500)
            $0.topThreadCount = 10
        }
        config.enable(PerfProfilerMonitor.self) {
            $0.samplingInterval = .milliseconds(10)
            $0.windowInterval = .seconds(5)
            $0.mainThreadOnly = false
        }
        config.enable(PerfHangMonitor.self) {
            $0.hitchThreshold = .milliseconds(50)
            $0.unresponsiveThreshold = .milliseconds(500)
            $0.checkInterval = .milliseconds(100)
            $0.tracksRunLoopPhases = true
            $0.phaseRecordingThreshold = .milliseconds(20)
        }
        return config
    }

    /// 最小预设：只捕获崩溃与卡顿这两类必须知道的问题。
    ///
    /// 适合对开销极度敏感、或只想先接一点点看看效果的场景。
    public static var minimal: PerfConfiguration {
        var config = PerfConfiguration()
        config.redaction = .strict
        config.storage.totalQuota = .megabytes(10)

        config.enable(PerfCrashMonitor.self)
        config.enable(PerfHangMonitor.self) {
            $0.tracksRunLoopPhases = false
            $0.tracksQueueLatency = false
            $0.hitchThreshold = .seconds(1)
        }
        return config
    }
}
