# PerformanceSystemKit

系统原语的唯一封装：CPU、内存、磁盘、进程指标。**没有这个模块，采集层就不知道该去哪儿拿数据。**

## 职责

把 mach/Darwin 的底层 API（`task_info`、`host_statistics64`、`task_threads`、`proc_pid_rusage`、`sysctl`）封装成类型安全的 Swift 接口。整个工程对系统 API 的调用**只允许出现在这里**——上一版把「取 CPU 和内存」写了三遍，实现还不一致，导致同一时刻的「内存占用」在不同报表里是两个数。

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfCPUMetrics` | 进程累计 CPU 时间、线程 CPU 占用、线程数 |
| `PerfMemoryMetrics` | 物理足迹、常驻内存、可用内存、系统可用 |
| `PerfDiskMetrics` | 进程磁盘 I/O、卷容量 |
| `PerfProcessMetrics` | 进程创建时间、内核活动计数、调试器检测 |
| `PerfSystemSnapshot` | 一次性环境快照（卡顿/崩溃时携带） |

## 关键设计

- **累计值 vs 百分比**：CPU 时间、磁盘 I/O 都返回**累计值**，由调用方按采样间隔做差分。百分比脱离时间窗口就没有意义。
- **正确指标**：内存用 `TASK_VM_INFO.phys_footprint`（iOS jetsam 判定依据）而不是 `TASK_BASIC_INFO.resident_size`（含共享页，系统性高估）。
- **iOS 上诚实返回 nil**：进程磁盘 I/O 依赖 `proc_pid_rusage`，而它在 iOS SDK 里没有公开声明，用它等于私有 API。iOS 上该函数**返回 nil 并标记 `has_disk_io = false`**，而不是返回 0（会被误读成「没有磁盘活动」）。
- **平台差异收敛**：两端可用性不同的系统 API 经 `CPerfSystem` C 垫片隔离，Swift 层只看 `has_*` 标志。
