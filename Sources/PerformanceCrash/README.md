# PerformanceCrash

崩溃捕获：signal / mach exception / 未捕获 ObjC 异常。

## 职责

崩溃现场只写最少的原始字节（async-signal-safe），下次启动解析成结构化数据上报。接管的信号：`SIGSEGV / SIGBUS / SIGILL / SIGFPE / SIGABRT / SIGTRAP`。

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfCrashMonitor` | 监测器，配置见 `PerfCrashMonitorOptions` |
| `PerfCrashReport` | 上次崩溃：信号、时间、现场栈、镜像清单 |
| `PerfCrashReportParser` | 裸报告解析（下次启动时执行） |
| `PerfUncaughtExceptionReport` | 未捕获 ObjC 异常：name / reason / callStack |

## 关键设计

- **只写原始字节，不解析**：崩溃现场只能用 async-signal-safe 函数，`malloc`、`printf`、ObjC 消息都不行。裸报告（行式文本）写到预分配缓冲，解析留到下次启动进程健康时。
- **备用信号栈**：栈溢出导致的 SIGSEGV 里当前栈没空间跑 handler，不给备用栈 handler 自己会二次崩溃。
- **O_EXCL 不覆盖**：多线程同时崩溃时保住第一份比拿到最后一份更有价值。
- **恢复默认 handler 并重抛**：让系统按正常流程生成它自己的崩溃日志——否则系统报告和 MetricKit 的 `MXCrashDiagnostic` 都会丢。
- **镜像清单**：UUID + ASLR slide 是服务端符号化的必要输入。上一版只在文档里写了 atos 脚本，代码侧从未产出这些。
- **上一版只能拦 ObjC 异常**（`NSSetUncaughtExceptionHandler`）；SIGSEGV、SIGABRT、EXC_BAD_ACCESS 全拦不到。现在 signal 层接管了这些。
- **`pending.crash` 回捞**：`start()` 时先把上次留下的报告上报再装 handler，时间戳取崩溃发生时刻而非读取时刻。
