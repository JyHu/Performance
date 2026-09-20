import Foundation
import PerformanceCore

/// FPS / Jank / 掉帧监测。阶段 4 实现。
///
/// 这里也是 `PerfDisplayLinkDriver` 具体驱动的落点：
/// iOS 用 `CADisplayLink`（主线程回调），macOS 用 `CVDisplayLink`（专用线程回调）。
/// 上一版只写了 `CVDisplayLink`，是它无法在 iOS 上编译的直接原因之一。
public enum PerfRendering {
    public static let monitorID: PerfMonitorID = "rendering"

    public enum Kinds {
        public static let fps: PerfKind = "rendering.fps"
        public static let jank: PerfKind = "rendering.jank"
    }
}
