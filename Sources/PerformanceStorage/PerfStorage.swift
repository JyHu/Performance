import Foundation
import PerformanceCore

/// JSONL 分片持久化。
///
/// 选 JSONL 而非 SQLite 的权衡：写入路径极简（append-only，一次 `write(2)`）、
/// 崩溃安全性天然（进程被杀最多损失最后一行）、可直接 `tail` 和 `grep` 排查。
/// 代价是没有索引——通过「按 kind 大类分文件 + 分片按时间有序」来弥补，
/// 使时间范围与类型过滤都能整片跳过。
///
/// 阶段 2 实现。
public enum PerfStorage {
    public static let moduleVersion = PerfFramework.version
}
