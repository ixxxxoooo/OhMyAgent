// @author ixxxxoooo
// 用量扫描:从 Claude Code 的会话记录(`~/.claude/projects/**/*.jsonl`,含子代理文件)汇总真实用量。
// - 每日活动与 token:取每条 assistant 消息的 `usage`(同一消息被流式拆成多行,按 message.id + requestId 去重、各字段取最大值);
// - 费用:取 Claude Code 自己在会话文件里写的 `cost-state`(每个会话最后一条,按模型拆分的 costUSD),不自己猜价格;
// - 每个文件的汇总按「大小 + 修改时间」缓存到 `cacheURL`,再次打开只重新解析变化的文件。
// `stats-cache.json` 已被新版 Claude Code 弃用(本机停在 2026-02),只在没有任何会话记录时作为兜底。

import Foundation

/// 单日汇总(单个文件内)。
struct DayUsage: Codable, Equatable {
    var messages = 0
    var tools = 0
    /// 模型 → [输入, 输出, 缓存读取, 缓存写入]
    var tokens: [String: [Int]] = [:]
}

/// 单个会话文件的汇总。
struct FileUsage: Codable, Equatable {
    var size: Int
    var mtime: Double
    var sessionId: String?
    var days: [String: DayUsage] = [:]
    /// 最后一条 cost-state 里按模型的费用
    var cost: [String: Double] = [:]
    var costTotal: Double = 0
}

/// 会话记录扫描器。
public struct UsageScanner: Sendable {
    public let projectsDirectory: URL
    /// 汇总缓存文件;为 nil 时不缓存
    public let cacheURL: URL?

    /// - Parameters:
    ///   - projectsDirectory: `~/.claude/projects`
    ///   - cacheURL: 缓存文件位置(应用支持目录下)
    public init(projectsDirectory: URL, cacheURL: URL?) {
        self.projectsDirectory = projectsDirectory
        self.cacheURL = cacheURL
    }

    private struct Cache: Codable { var version = 1; var files: [String: FileUsage] = [:] }

    /// 扫描并汇总;没有任何会话记录(目录不存在或没有 assistant 用量)时返回 nil,由调用方兜底。
    public func scan() -> UsageStatsSnapshot? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: projectsDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        var cache = loadCache()
        var current: [String: FileUsage] = [:]
        var changed = false
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            if let cached = cache.files[url.path], cached.size == size, cached.mtime == mtime {
                current[url.path] = cached
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            var usage = Self.parse(data)
            usage.size = size
            usage.mtime = mtime
            current[url.path] = usage
            changed = true
        }
        if current.count != cache.files.count { changed = true }
        cache.files = current
        if changed { saveCache(cache) }
        return Self.merge(current)
    }

    // MARK: - 解析

    private static let assistantNeedle = Data("\"type\":\"assistant\"".utf8)
    private static let costNeedle = Data("\"type\":\"cost-state\"".utf8)

    /// 解析一个会话文件(纯函数,便于测试)。
    /// - Parameter data: 文件内容
    /// - Returns: 汇总;`size`/`mtime` 由调用方填写
    static func parse(_ data: Data) -> FileUsage {
        var usage = FileUsage(size: 0, mtime: 0)
        var messages: [String: (day: String, model: String, tokens: [Int])] = [:]
        var toolDays: [String: String] = [:]
        var lastCost: [String: Any]?
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let isAssistant = line.range(of: assistantNeedle) != nil
            let isCost = !isAssistant && line.range(of: costNeedle) != nil
            guard isAssistant || isCost, let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if isCost { lastCost = object; continue }
            if usage.sessionId == nil { usage.sessionId = object["sessionId"] as? String }
            guard let message = object["message"] as? [String: Any], let model = message["model"] as? String, model != "<synthetic>",
                  let raw = message["usage"] as? [String: Any], let stamp = object["timestamp"] as? String else { continue }
            let day = localDay(stamp)
            let key = "\(message["id"] as? String ?? (object["uuid"] as? String ?? "")):\(object["requestId"] as? String ?? "")"
            let fields = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].map { (raw[$0] as? NSNumber)?.intValue ?? 0 }
            if var existing = messages[key] {
                // 同一消息的多行(按内容块流式写入):各字段取最大值
                for index in 0..<4 { existing.tokens[index] = max(existing.tokens[index], fields[index]) }
                messages[key] = existing
            } else {
                messages[key] = (day, model, fields)
            }
            for block in (message["content"] as? [[String: Any]]) ?? [] where (block["type"] as? String) == "tool_use" {
                if let id = block["id"] as? String { toolDays[id] = day }
            }
        }
        for message in messages.values {
            var entry = usage.days[message.day, default: DayUsage()]
            entry.messages += 1
            var total = entry.tokens[message.model, default: [0, 0, 0, 0]]
            for index in 0..<4 { total[index] += message.tokens[index] }
            entry.tokens[message.model] = total
            usage.days[message.day] = entry
        }
        for day in toolDays.values { usage.days[day, default: DayUsage()].tools += 1 }
        if let lastCost {
            usage.costTotal = (lastCost["totalCostUSD"] as? NSNumber)?.doubleValue ?? 0
            if usage.sessionId == nil { usage.sessionId = lastCost["sessionId"] as? String }
            for (model, raw) in (lastCost["modelUsage"] as? [String: Any]) ?? [:] {
                if let value = (raw as? [String: Any])?["costUSD"] as? NSNumber { usage.cost[model] = value.doubleValue }
            }
        }
        return usage
    }

    /// 时间戳(ISO8601,UTC)→ 本地日期 `yyyy-MM-dd`;按「到小时」缓存换算结果,避免逐条解析。
    private static let dayLock = NSLock()
    nonisolated(unsafe) private static var dayCache: [String: String] = [:]
    static func localDay(_ stamp: String) -> String {
        let key = String(stamp.prefix(13))
        dayLock.lock()
        defer { dayLock.unlock() }
        if let hit = dayCache[key] { return hit }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd'T'HH"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = parser.date(from: key).map(formatter.string(from:)) ?? String(stamp.prefix(10))
        dayCache[key] = day
        return day
    }

    // MARK: - 合并

    /// 把各文件汇总合并为统计快照;没有任何 assistant 用量时返回 nil。
    static func merge(_ files: [String: FileUsage]) -> UsageStatsSnapshot? {
        var activity: [String: (messages: Int, tools: Int, sessions: Set<String>)] = [:]
        var dailyTokens: [String: [String: Int]] = [:]
        var totals: [String: [Int]] = [:]
        var sessionCost: [String: (total: Double, byModel: [String: Double])] = [:]
        for (path, file) in files {
            let session = file.sessionId ?? path
            for (day, entry) in file.days {
                var item = activity[day, default: (0, 0, [])]
                item.messages += entry.messages
                item.tools += entry.tools
                if entry.messages > 0 { item.sessions.insert(session) }
                activity[day] = item
                for (model, tokens) in entry.tokens {
                    dailyTokens[day, default: [:]][model, default: 0] += tokens[0] + tokens[1]
                    var total = totals[model, default: [0, 0, 0, 0]]
                    for index in 0..<4 { total[index] += tokens[index] }
                    totals[model] = total
                }
            }
            // 同一会话出现在多个文件时只取费用最大的那份,避免重复累计
            if file.costTotal > (sessionCost[session]?.total ?? -1) { sessionCost[session] = (file.costTotal, file.cost) }
        }
        guard !activity.isEmpty else { return nil }
        var costByModel: [String: Double] = [:]
        for state in sessionCost.values { for (model, value) in state.byModel { costByModel[model, default: 0] += value } }
        let models = Set(totals.keys).union(costByModel.keys).map { model -> ModelUsageTotal in
            let tokens = totals[model] ?? [0, 0, 0, 0]
            return ModelUsageTotal(model: model, inputTokens: tokens[0], outputTokens: tokens[1], cacheReadTokens: tokens[2], cacheCreationTokens: tokens[3], costUSD: costByModel[model] ?? 0)
        }.sorted { ($0.outputTokens, $0.costUSD) > ($1.outputTokens, $1.costUSD) }
        let daily = activity.map { DailyActivity(date: $0.key, messageCount: $0.value.messages, sessionCount: $0.value.sessions.count, toolCallCount: $0.value.tools) }.sorted { $0.date < $1.date }
        let tokens = dailyTokens.map { DailyModelTokens(date: $0.key, byModel: $0.value) }.sorted { $0.date < $1.date }
        var snapshot = UsageStatsSnapshot(lastComputedDate: daily.last?.date, daily: daily, models: models, dailyTokens: tokens)
        snapshot.source = .transcripts(sessions: Set(files.map { $0.value.sessionId ?? $0.key }).count, costSessions: sessionCost.values.filter { $0.total > 0 }.count)
        return snapshot
    }

    // MARK: - 缓存

    private func loadCache() -> Cache {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 1 else { return Cache() }
        return cache
    }

    private func saveCache(_ cache: Cache) {
        guard let cacheURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
