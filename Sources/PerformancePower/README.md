# PerformancePower

电量与热状态监测。

## 职责

采样电量水平与充电状态，监听系统热状态变化，记录低电量模式。热状态尤其重要：到 `.serious` 系统开始降频并限制刷新率，此时观测到的卡顿是**被降频导致的**，与代码无关。

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfPowerMonitor` | 监测器，配置见 `PerfPowerMonitorOptions` |
| `PerfThermalSample` | 热状态 + 低电量模式 |
| `PerfBatterySample` | 电量、充电状态、相对上次采样的变化 |

## 关键设计

- **热状态变化时上报，不每次采样都记**：低频事件，重复值没有信息量。
- **降频标识**：`isThrottling` 在 serious/critical 时为 true。没有这个维度，因降频导致的卡顿会被误判成代码退化。
- **电量是差分**：`deltaSinceLastSample` 展示耗电速率，比绝对值更有信息量。
- **iOS 需开电池监控**：`UIDevice.isBatteryMonitoringEnabled` 有轻微开销，做成可关。
- **平台差异收敛**：iOS 用 `UIDevice`，macOS 用 `IOPSCopyPowerSourcesInfo`，差异集中在 `readBattery()`。
