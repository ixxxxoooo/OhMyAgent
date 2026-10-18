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

/// 单日按模型的 token 用量(来自 `dailyModelTokens`)。
public struct DailyModelTokens: Sendable, Equatable, Identifiable {
    public var id: String { date }
    public var date: String
    /// 模型 → 当日 token 数
    public var byModel: [String: Int]

    /// 当日总 token。
    public var total: Int { byModel.values.reduce(0, +) }
}

/// 统计快照。
public struct UsageStatsSnapshot: Sendable, Equatable {
    public var lastComputedDate: String?
    public var daily: [DailyActivity]
    public var models: [ModelUsageTotal]
    /// 每日按模型 token(可能为空:旧版缓存没有该字段)
    public var dailyTokens: [DailyModelTokens] = []
    /// 数据来源
    public var source: Source = .statsCache

    /// 数据来源:会话记录(真实、实时)或旧的 stats-cache.json(新版 Claude Code 已不再更新)。
    public enum Source: Sendable, Equatable {
        case statsCache
        /// - sessions: 参与统计的会话数;costSessions: 其中带有费用记录的会话数
        case transcripts(sessions: Int, costSessions: Int)
    }

    public static let empty = UsageStatsSnapshot(lastComputedDate: nil, daily: [], models: [])

    /// 全部模型累计 token(输入 + 输出,不含缓存)。
    public var totalTokens: Int { models.reduce(0) { $0 + $1.inputTokens + $1.outputTokens } }

    /// 全部模型累计费用(USD)。
    public var totalCostUSD: Double { models.reduce(0) { $0 + $1.costUSD } }

    /// 缓存命中率:缓存读取 /(输入 + 缓存读取 + 缓存写入);没有输入数据时为 nil。
    public var cacheHitRatio: Double? {
        let read = models.reduce(0) { $0 + $1.cacheReadTokens }
        let denominator = models.reduce(0) { $0 + $1.inputTokens + $1.cacheCreationTokens } + read
        return denominator > 0 ? Double(read) / Double(denominator) : nil
    }

    /// 最近 N 天(按文件中最新日期倒推)的逐日活动;缺失的日期补零,保证图表横轴连续。
    /// - Parameter days: 天数(≥ 1)
    public func dailyWindow(days: Int) -> [DailyActivity] {
        guard days > 0, let last = daily.last?.date, let end = Self.parseDay(last) else { return [] }
        let byDate = Dictionary(daily.map { ($0.date, $0) }, uniquingKeysWith: { _, last in last })
        let calendar = Calendar(identifier: .gregorian)
        return (0..<days).reversed().compactMap { offset -> DailyActivity? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
            let key = Self.formatDay(day)
            return byDate[key] ?? DailyActivity(date: key, messageCount: 0, sessionCount: 0, toolCallCount: 0)
        }
    }

    /// 最近 N 天的每日 token 序列(同样补零)。
    public func dailyTokenWindow(days: Int) -> [DailyModelTokens] {
        guard days > 0, let last = (dailyTokens.last?.date ?? daily.last?.date), let end = Self.parseDay(last) else { return [] }
        let byDate = Dictionary(dailyTokens.map { ($0.date, $0) }, uniquingKeysWith: { _, last in last })
        let calendar = Calendar(identifier: .gregorian)
        return (0..<days).reversed().compactMap { offset -> DailyModelTokens? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
            let key = Self.formatDay(day)
            return byDate[key] ?? DailyModelTokens(date: key, byModel: [:])
        }
    }

    /// 解析 `yyyy-MM-dd`(固定公历、UTC,避免时区导致日期偏移)。
    public static func parseDay(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    /// 格式化为 `yyyy-MM-dd`。
    static func formatDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 最近 N 天(按文件中最新日期倒推)的汇总。
    public func recent(days: Int) -> (messages: Int, sessions: Int, toolCalls: Int) {
        let slice = daily.suffix(days)
        return (slice.reduce(0) { $0 + $1.messageCount }, slice.reduce(0) { $0 + $1.sessionCount }, slice.reduce(0) { $0 + $1.toolCallCount })
    }
}

/// 统计读取器。
public enum UsageStats {
    /// 读取用量:优先从会话记录汇总(真实且实时),没有任何会话记录时退回 `stats-cache.json`。
    /// - Parameters:
    ///   - paths: Claude 配置路径
    ///   - cacheURL: 会话记录汇总缓存位置(可空)
    public static func load(paths: ClaudePaths, cacheURL: URL? = nil) -> UsageStatsSnapshot {
        let projects = paths.claudeDirectory.appendingPathComponent("projects")
        if let scanned = UsageScanner(projectsDirectory: projects, cacheURL: cacheURL).scan() { return scanned }
        return loadStatsCache(paths: paths)
    }

    /// 读取旧统计文件;不存在或解析失败返回空快照。
    static func loadStatsCache(paths: ClaudePaths) -> UsageStatsSnapshot {
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
        let dailyTokens = ((object["dailyModelTokens"] as? [[String: Any]]) ?? []).compactMap { item -> DailyModelTokens? in
            guard let date = item["date"] as? String else { return nil }
            let raw = (item["tokensByModel"] as? [String: Any]) ?? [:]
            return DailyModelTokens(date: date, byModel: raw.compactMapValues { ($0 as? NSNumber)?.intValue })
        }.sorted { $0.date < $1.date }
        return UsageStatsSnapshot(lastComputedDate: object["lastComputedDate"] as? String, daily: daily, models: models, dailyTokens: dailyTokens)
    }
}
