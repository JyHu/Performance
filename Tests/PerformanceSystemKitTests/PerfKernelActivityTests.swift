import Foundation
import Testing

import PerformanceCore
@testable import PerformanceSystemKit

@Suite("内核活动计数")
struct PerfKernelActivityTests {
    @Test("两个平台都能读到缺页与上下文切换")
    func readsKernelActivity() throws {
        let activity = try #require(PerfProcessMetrics.kernelActivity())

        #expect(activity.faults > 0)
        #expect(activity.contextSwitches > 0)
        // pageins 可能为 0（页都在内存里），这是合法值
        #expect(activity.pageins >= 0)
    }

    @Test("计数单调递增")
    func countsAreMonotonic() throws {
        let first = try #require(PerfProcessMetrics.kernelActivity())

        // 制造一些上下文切换
        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                usleep(2_000)
            }
        }
        group.wait()

        let second = try #require(PerfProcessMetrics.kernelActivity())
        #expect(second.contextSwitches >= first.contextSwitches)
        #expect(second.faults >= first.faults)
    }
}

@Suite("系统快照")
struct PerfSystemSnapshotTests {
    @Test("一次性带上全部环境指标")
    func capturesFullSnapshot() {
        let snapshot = PerfSystemSnapshot.capture()

        // 卡顿/ANR/崩溃发生时最怕的就是「知道卡了，但不知道当时内存和 CPU 什么样」
        #expect(snapshot.memory.footprintBytes > 0)
        #expect(snapshot.threadCount > 0)
        #expect(snapshot.cpuTime != nil)
    }

    @Test("主线程登记状态可自检")
    func reportsMainThreadRegistration() async {
        await MainActor.run { PerfSystemKit.registerMainThread() }
        // 未登记时「是否主线程」会一律返回 false，属于静默出错，
        // 所以需要一个能主动查的入口
        #expect(PerfSystemKit.isMainThreadRegistered)
    }
}
