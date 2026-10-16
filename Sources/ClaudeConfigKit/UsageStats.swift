// @author ixxxxoooo
// 用量统计:读取 Claude Code 的 `~/.claude/stats-cache.json`(通道 B,只读)。

import Foundation

/// 单日活动。
public struct DailyActivity: Sendable, Equatable, Identifiable {
    public var id: String { date }
    public var date: String
    public var messageCount: Int
    public var sessionCount: Int
    public var toolCallCount: Int
}

/// 按模型累计的 token。
public struct ModelUsageTotal: Sendable, Equatable, Identifiable {
    public var id: String { model }
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var costUSD: Double
}

/// 统计快照。
public struct UsageStatsSnapshot: Sendable, Equatable {
    public var lastComputedDate: String?
    public var daily: [DailyActivity]
    public var models: [ModelUsageTotal]

    public static let empty = UsageStatsSnapshot(lastComputedDate: nil, daily: [], models: [])

    /// 最近 N 天(按文件中最新日期倒推)的汇总。
    public func recent(days: Int) -> (messages: Int, sessions: Int, toolCalls: Int) {
        let slice = daily.suffix(days)
        return (slice.reduce(0) { $0 + $1.messageCount }, slice.reduce(0) { $0 + $1.sessionCount }, slice.reduce(0) { $0 + $1.toolCallCount })
    }
}

/// 统计读取器。
public enum UsageStats {
    /// 读取统计文件;不存在或解析失败返回空快照。
    public static func load(paths: ClaudePaths) -> UsageStatsSnapshot {
        guard let object = try? JSONFile(paths.claudeDirectory.appendingPathComponent("stats-cache.json")).read() else { return .empty }
        let daily = ((object["dailyActivity"] as? [[String: Any]]) ?? []).compactMap { item -> DailyActivity? in
            guard let date = item["date"] as? String else { return nil }
            return DailyActivity(date: date, messageCount: (item["messageCount"] as? Int) ?? 0,
                                 sessionCount: (item["sessionCount"] as? Int) ?? 0, toolCallCount: (item["toolCallCount"] as? Int) ?? 0)
        }.sorted { $0.date < $1.date }
        let models = ((object["modelUsage"] as? [String: Any]) ?? [:]).compactMap { name, raw -> ModelUsageTotal? in
            guard let item = raw as? [String: Any] else { return nil }
            func int(_ key: String) -> Int { (item[key] as? NSNumber)?.intValue ?? 0 }
            return ModelUsageTotal(model: name, inputTokens: int("inputTokens"), outputTokens: int("outputTokens"),
                                   cacheReadTokens: int("cacheReadInputTokens"), cacheCreationTokens: int("cacheCreationInputTokens"),
                                   costUSD: (item["costUSD"] as? NSNumber)?.doubleValue ?? 0)
        }.sorted { $0.outputTokens > $1.outputTokens }
        return UsageStatsSnapshot(lastComputedDate: object["lastComputedDate"] as? String, daily: daily, models: models)
    }
}
