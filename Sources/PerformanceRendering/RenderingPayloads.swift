import Foundation
import PerformanceCore

/// 一个统计窗口内的帧率情况。
public struct PerfFPSSample: PerfPayload, Equatable {
    public static let kind: PerfKind = "rendering.fps"

    /// 实际帧率。
    public let fps: Double
    /// 窗口内的目标帧率。
    ///
    /// 必须一并记录：ProMotion 设备会在 10~120Hz 之间动态变化，
    /// 低电量模式、后台状态、外接显示器都会改变它。
    /// 只记 `fps: 40` 无法判断这是掉帧还是系统主动降频——
    /// 上一版把目标帧率当常量，在 120Hz 设备上会把正常帧误判成掉帧。
    public let targetFPS: Double
    public let frameCount: Int
    public let windowMs: Double

    /// 窗口内超过目标间隔的帧数。
    public let jankFrameCount: Int
    /// 窗口内最长的一帧（毫秒）。
    public let worstFrameMs: Double

    /// 卡顿时间占比：因超时而多花的时间 / 窗口总时长。
    ///
    /// 比单看 FPS 更能反映体感。60 帧里有 1 帧卡了 500ms，
    /// FPS 看起来还有 58，但用户实际感受到的是明显的一次顿挫。
    public let hitchTimeRatio: Double

    public init(
        fps: Double,
        targetFPS: Double,
        frameCount: Int,
        windowMs: Double,
        jankFrameCount: Int,
        worstFrameMs: Double,
        hitchTimeRatio: Double
    ) {
        self.fps = fps
        self.targetFPS = targetFPS
        self.frameCount = frameCount
        self.windowMs = windowMs
        self.jankFrameCount = jankFrameCount
        self.worstFrameMs = worstFrameMs
        self.hitchTimeRatio = hitchTimeRatio
    }
}

/// 单次掉帧事件。
public struct PerfJankEvent: PerfPayload, Equatable {
    public static let kind: PerfKind = "rendering.jank"

    /// 本帧实际耗时（毫秒）。
    public let frameMs: Double
    /// 本帧的目标耗时（毫秒）。
    public let targetFrameMs: Double
    /// 相当于丢了几帧。
    public let droppedFrames: Int

    public init(frameMs: Double, targetFrameMs: Double, droppedFrames: Int) {
        self.frameMs = frameMs
        self.targetFrameMs = targetFrameMs
        self.droppedFrames = droppedFrames
    }
}
