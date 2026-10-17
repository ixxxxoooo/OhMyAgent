// @author ixxxxoooo
// 会话汇总:把本次运行的资源峰值、卡顿、耗时 Top 与最近容量快照汇成一份,
// 退出时写一条「会话汇总」日志,诊断包导出时附上同样的文本,事后不用翻日志就能看整体画像。

import Foundation

/// 本次运行的性能画像。
public enum PerfSession {
    /// 进程内首次访问的时间,近似为运行起点(应在启动时访问一次)。
    private static let startedAt = ContinuousClock.now

    /// 记录运行起点(幂等,启动时调用一次)。
    public static func markStart() { _ = startedAt }

    /// 运行时长(秒)。
    public static var uptimeSeconds: Int {
        Int(OMLogger.milliseconds(since: startedAt) / 1000)
    }

    /// 汇总字段(退出日志用)。
    /// - Parameters:
    ///   - sampler: 资源采样器
    ///   - hitch: 卡顿监视器
    ///   - stats: 耗时聚合
    public static func fields(sampler: ResourceSampler = .shared, hitch: MainThreadHitchMonitor = .shared, stats: PerfStats = .shared) -> [String: String] {
        let totals = sampler.totals
        let last = sampler.history().last
        var fields: [String: String] = [
            "uptimeSec": "\(uptimeSeconds)",
            "peakMB": String(format: "%.1f", totals.peakMB),
            "samples": "\(totals.samples)",
            "hitches": "\(hitch.totals.count)",
            "maxHitchMs": "\(hitch.totals.maxMs)",
        ]
        if let last {
            fields["lastFootprintMB"] = String(format: "%.1f", last.footprintMB)
            fields["lastChildMB"] = String(format: "%.1f", last.childrenFootprintMB)
        }
        let top = stats.snapshot(top: 5).map { "\($0.name)=\(Int($0.totalMs))ms" }.joined(separator: ",")
        if !top.isEmpty { fields["topSpans"] = top }
        return fields
    }

    /// 写入「会话汇总」日志,并输出一轮「性能汇总」。
    public static func logSummary(to logger: OMLogger = Log.perf) {
        logger.info("会话汇总", fields())
        PerfStats.shared.logSummary(to: logger)
    }

    /// 诊断包用的多行文本:运行画像、footprint 时序(最近 20 点)、耗时 Top 10。
    public static func reportLines(sampler: ResourceSampler = .shared, hitch: MainThreadHitchMonitor = .shared, stats: PerfStats = .shared) -> [String] {
        let totals = sampler.totals
        var lines = [
            "运行 \(uptimeSeconds)s · 采样 \(totals.samples) 次 · footprint 峰值 \(String(format: "%.1f", totals.peakMB)) MB",
            "主线程卡顿 \(hitch.totals.count) 次 · 最长 \(hitch.totals.maxMs) ms",
            "",
            "footprint 时序(MB,本进程 / 子进程合计 / CPU%):",
        ]
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        for sample in sampler.history().suffix(20) {
            let cpu = sample.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "-"
            lines.append("  \(formatter.string(from: sample.date))  \(String(format: "%.0f", sample.footprintMB)) / \(String(format: "%.0f", sample.childrenFootprintMB))  \(cpu)")
        }
        lines += ["", "耗时 Top 10(累计 ms / 次数 / P95 / 最大):"]
        for row in stats.snapshot(top: 10) {
            lines.append("  \(row.name)  \(Int(row.totalMs))ms / \(row.count) / \(Int(row.p95Ms))ms / \(Int(row.maxMs))ms")
        }
        return lines
    }
}
