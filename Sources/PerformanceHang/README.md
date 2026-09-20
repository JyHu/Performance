# PerformanceHang

主线程健康监测：顿挫 / ANR / 死锁 / RunLoop 阶段分解 / 主队列时延。

## 职责

四类「主线程出问题」用一个 RunLoop observer + 一个 watchdog 覆盖，且 watchdog **不向主队列投递任何东西**。

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfHangMonitor` | 监测器，配置见 `PerfHangMonitorOptions` |
| `PerfHangEvent` | ANR：阶段（hitch/unresponsive/severe）、持续时长、现场堆栈 |
| `PerfDeadlockEvent` | 死锁：寄存器快照、主线程栈、全线程栈 |
| `PerfHitchEvent` | 单次 RunLoop 迭代超时 |
| `PerfRunLoopPhaseSample` | timer / source 阶段耗时分解 |
| `PerfQueueLatencySample` | 主队列排队时延 |

## 关键设计

- **watchdog 不投递任何东西**：常见做法是后台定时往主队列扔信号量测响应。这里反过来——主线程的 RunLoop observer 被唤醒时记时间戳、休眠时清掉，watchdog 只**读**。好处：主线程零额外负担；卡顿**还在进行时**就能发现，抓到的是真正的现场堆栈；主队列积压时投递式探针自己也会排队，测出的时间失真。
- **死锁判据是寄存器不是耗时**：跑得慢的代码 PC 持续变化，真卡死的不变。只看耗时无法区分「死锁」和「在算一个很大的循环」。
- **每级只报一次**：一次 10 秒卡顿在 250ms 检查周期下会被检查 40 次，只产出 unresponsive 与 severe 各一条，避免冲垮缓冲。
- **时间戳取卡顿开始时刻**：否则时间线上与同期 CPU/内存采样错位。
- **无回溯能力时降级**：`context.backtrace` 为 nil 时只报 ANR，不崩溃。
- **死锁带全线程栈**：死锁至少涉及两方，只看主线程只知道它在等锁，不知道锁被谁持有。
