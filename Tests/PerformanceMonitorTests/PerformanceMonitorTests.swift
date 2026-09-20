import Testing

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

/// 阶段 4/5 填充各监测器的行为用例。
/// 所有用例都注入 `PerfManualClock` + `PerfManualScheduler` + `PerfCollectingSink`，
/// 不使用 `Thread.sleep`——上一版唯一的真测试单次要跑 10 秒以上。
@Suite("监测器")
struct PerformanceMonitorTests {
    @Test("各监测器的 kind 命名空间互不重叠")
    func kindNamespacesAreDisjoint() {
        let groups: [String] = [
            PerfResource.Kinds.cpu,
            PerfDisk.Kinds.space,
            PerfRendering.Kinds.fps,
            PerfHang.Kinds.anr,
            PerfProfiler.Kinds.hotspot,
            PerfLaunch.Kinds.cold,
            PerfTrace.Kinds.span,
            PerfNetwork.Kinds.request,
            PerfCrash.Kinds.signal,
            PerfPower.Kinds.thermal,
            PerfMetricKit.Kinds.payload,
        ].map(\.group)

        #expect(Set(groups).count == groups.count)
    }

    @Test("监测器标识唯一")
    func monitorIDsAreUnique() {
        let ids: [PerfMonitorID] = [
            PerfResource.monitorID,
            PerfDisk.monitorID,
            PerfRendering.monitorID,
            PerfHang.monitorID,
            PerfProfiler.monitorID,
            PerfLaunch.monitorID,
            PerfTrace.monitorID,
            PerfNetwork.monitorID,
            PerfCrash.monitorID,
            PerfPower.monitorID,
            PerfMetricKit.monitorID,
        ]

        #expect(Set(ids).count == ids.count)
    }
}
