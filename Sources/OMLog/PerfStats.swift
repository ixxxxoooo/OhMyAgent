// @author ixxxxoooo
// 耗时聚合:按跨度名统计次数、总耗时、最大值与 P50/P95(固定桶直方图),并周期性输出「性能汇总」日志。
// 单条耗时日志只能看到某一次慢,聚合才能回答「整体时间花在哪」。

import Foundation
import Synchronization

/// 一个跨度名的聚合结果。
public struct PerfStatRow: Sendable, Equatable {
    /// 跨度名。
    public let name: String
    /// 调用次数。
    public let count: Int
    /// 累计耗时(毫秒)。
    public let totalMs: Double
    /// 单次最大耗时(毫秒)。
    public let maxMs: Double
    /// 中位数估计(毫秒,取所在桶上界,不超过最大值)。
    public let p50Ms: Double
    /// 95 分位估计(毫秒,取所在桶上界,不超过最大值)。
    public let p95Ms: Double
}

/// 耗时聚合器(线程安全)。`PerfSpan.end` 会自动写入,调用点无需改动。
public final class PerfStats: @unchecked Sendable {
    public static let shared = PerfStats()

    /// 桶上界(毫秒);最后一个桶表示更大的所有值。
    static let bounds: [Double] = [0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096]
    /// 超出名称上限后统一归入的名字。
    static let overflowName = "其他"

    private struct Entry {
        var count = 0
        var totalMicros = 0
        var maxMicros = 0
        var buckets = [Int](repeating: 0, count: PerfStats.bounds.count + 1)
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var reporter: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let maxNames: Int

    /// 创建聚合器。
    /// - Parameter maxNames: 最多区分的跨度名个数(防止动态名字撑大内存),超出归入「其他」
    public init(maxNames: Int = 256) {
        self.maxNames = max(maxNames, 1)
    }

    /// 记录一次耗时。
    /// - Parameters:
    ///   - name: 跨度名
    ///   - micros: 耗时(微秒),负数按 0 处理
    public func record(name: String, micros: Int) {
        let value = max(micros, 0)
        let ms = Double(value) / 1000
        let index = Self.bounds.firstIndex(where: { ms <= $0 }) ?? Self.bounds.count
        state.withLock { state in
            let key = (state.entries[name] != nil || state.entries.count < maxNames) ? name : Self.overflowName
            var entry = state.entries[key] ?? Entry()
            entry.count += 1
            entry.totalMicros += value
            entry.maxMicros = max(entry.maxMicros, value)
            entry.buckets[index] += 1
            state.entries[key] = entry
        }
    }

    /// 取聚合快照,按累计耗时降序。
    /// - Parameter top: 最多返回的行数
    /// - Returns: 聚合行
    public func snapshot(top: Int = 10) -> [PerfStatRow] {
        let entries = state.withLock { $0.entries }
        let rows = entries.map { name, entry -> PerfStatRow in
            let maxMs = Double(entry.maxMicros) / 1000
            return PerfStatRow(
                name: name, count: entry.count, totalMs: Double(entry.totalMicros) / 1000, maxMs: maxMs,
                p50Ms: Self.percentile(0.5, entry: entry, maxMs: maxMs),
                p95Ms: Self.percentile(0.95, entry: entry, maxMs: maxMs)
            )
        }
        return Array(rows.sorted { $0.totalMs > $1.totalMs }.prefix(max(top, 0)))
    }

    /// 清空全部聚合数据。
    public func reset() {
        state.withLock { $0.entries.removeAll() }
    }

    /// 把聚合结果写成「性能汇总」日志(每个跨度名一行,便于 grep)。
    /// - Parameters:
    ///   - top: 取累计耗时最高的前几项
    ///   - logger: 目标日志器
    public func logSummary(top: Int = 8, to logger: OMLogger = Log.perf) {
        for row in snapshot(top: top) {
            logger.info("性能汇总", [
                "name": row.name,
                "count": "\(row.count)",
                "totalMs": Self.format(row.totalMs),
                "p50Ms": Self.format(row.p50Ms),
                "p95Ms": Self.format(row.p95Ms),
                "maxMs": Self.format(row.maxMs),
            ])
        }
    }

    /// 启动周期性汇总日志(幂等,重复调用以第一次为准)。
    /// - Parameter intervalSeconds: 间隔秒数,下限 10
    public func startPeriodicReport(intervalSeconds: Int = 300) {
        let interval = max(intervalSeconds, 10)
        state.withLock { state in
            guard state.reporter == nil else { return }
            state.reporter = Task.detached(priority: .utility) { [self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    logSummary()
                }
            }
        }
    }

    /// 停止周期性汇总。
    public func stopPeriodicReport() {
        state.withLock { state in
            state.reporter?.cancel()
            state.reporter = nil
        }
    }

    /// 按累计计数估计分位数:返回目标排名所在桶的上界,且不超过观测最大值。
    private static func percentile(_ p: Double, entry: Entry, maxMs: Double) -> Double {
        guard entry.count > 0 else { return 0 }
        let rank = max(Int((Double(entry.count) * p).rounded(.up)), 1)
        var seen = 0
        for (index, bucket) in entry.buckets.enumerated() {
            seen += bucket
            if seen >= rank {
                let upper = index < bounds.count ? bounds[index] : maxMs
                return min(upper, maxMs)
            }
        }
        return maxMs
    }

    /// 毫秒数保留一位小数。
    static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
