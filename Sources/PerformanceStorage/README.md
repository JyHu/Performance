# PerformanceStorage

JSONL 分片持久化：采集数据的落盘、查询、归档、清理。

## 职责

数据从 `PerfRecordBuffer` 取出后，经过脱敏、JSON 编码，落到本地 JSONL 分片文件。查询时按类型过滤、按时间范围过滤，可导出为 gzip 归档。

## 主要类型

| 类型 | 职责 |
|---|---|
| `PerfStore` | 对外门面：写入、查询、导出、清理 |
| `PerfShardWriter` | 单个 kind 大类的分片写入（append-only） |
| `PerfShardReader` | 流式读取，容错跳行 |
| `PerfShardLocator` | 目录与分片文件命名 |
| `PerfRetentionEnforcer` | 配额 + 过期清理 |
| `PerfStoragePipeline` | 把缓冲搬运到存储 + 导出器 |
| `PerfGzip` | 标准 gzip 压缩（真容器，可 `gunzip`） |
| `PerfQueryResult` | 查询结果，自述完整性 |

## 目录布局

```
<Caches>/Performance/
├── sessions/
│   ├── 20260920T103045-A1B2C3/
│   │   ├── manifest.json          设备 / OS / app 版本 / 启停时间
│   │   ├── hang-000.jsonl         按 kind 大类分片
│   │   └── resource-000.jsonl.gz  非当前分片自动 gzip 归档
│   └── 20260919T221130-D4E5F6/
└── crash/
    └── pending.crash              崩溃现场裸报告
```

## 关键设计

- **用 `write(2)` 而非 `FileHandle`**：后者出错抛 ObjC 异常，Swift 捕获不到会直接终止进程。`O_APPEND` 让多写入者不交错。
- **崩溃安全**：进程被杀最多损失最后一行；读取侧跳过坏行并计数，不中断。崩溃前那几秒数据往往最有价值。
- **按 kind 分文件 + session 名带时间戳**：弥补 JSONL 无索引——类型与时间范围过滤可整片跳过。
- **配额 + 保留期**：默认总量 50MB、保留 7 天，超限从最旧 session 整体删除；**当前 session 永不删**。
- **脱敏 fail-closed**：`PerfRedactionPolicy` 处理 URL/path/符号名，失败时宁可丢数据也不放出未处理内容。
- **查询结果自述完整性**：`isComplete` / `skippedLineCount` / `truncatedShards` 暴露数据缺口——基于残缺数据下结论比没有结论更危险。
