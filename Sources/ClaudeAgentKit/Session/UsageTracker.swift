// @author ixxxxoooo
// 用量统计:累计 token、按模型增量、上下文窗口与 `_meta.quota` 构造。

import ACPKit
import Foundation

/// 一组 token 计数。
struct TokenTally: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// 从 Anthropic `usage` 对象(下划线字段)构造。
    init(usage: JSONValue?) {
        input = usage?["input_tokens"]?.intValue ?? 0
        output = usage?["output_tokens"]?.intValue ?? 0
        cacheRead = usage?["cache_read_input_tokens"]?.intValue ?? 0
        cacheWrite = usage?["cache_creation_input_tokens"]?.intValue ?? 0
    }

    /// 从 `modelUsage` 条目(驼峰字段)构造。
    init(modelUsage: JSONValue?) {
        input = Self.count(modelUsage?["inputTokens"])
        output = Self.count(modelUsage?["outputTokens"])
        cacheRead = Self.count(modelUsage?["cacheReadInputTokens"])
        cacheWrite = Self.count(modelUsage?["cacheCreationInputTokens"])
    }

    private static func count(_ value: JSONValue?) -> Int {
        guard let number = value?.doubleValue, number.isFinite else { return 0 }
        return Int(number)
    }

    static func + (lhs: TokenTally, rhs: TokenTally) -> TokenTally {
        TokenTally(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }

    static func - (lhs: TokenTally, rhs: TokenTally) -> TokenTally {
        TokenTally(input: lhs.input - rhs.input, output: lhs.output - rhs.output, cacheRead: lhs.cacheRead - rhs.cacheRead, cacheWrite: lhs.cacheWrite - rhs.cacheWrite)
    }

    var hasNegative: Bool { input < 0 || output < 0 || cacheRead < 0 || cacheWrite < 0 }

    /// 配额元数据中的 token 计数对象。
    var quotaJSON: JSONValue {
        ["totalTokens": .int(total), "inputTokens": .int(input), "cachedInputTokens": .int(cacheRead),
         "cachedWriteTokens": .int(cacheWrite), "outputTokens": .int(output), "reasoningOutputTokens": 0]
    }
}

/// 会话用量状态。
struct UsageTracker {
    static let defaultContextWindow = 200_000

    /// 会话累计(仅非自治结果计入)
    var accumulated = TokenTally()
    var accumulatedByModel: [String: TokenTally] = [:]
    /// 上一次 `modelUsage` 读数;nil 表示恢复会话后尚无读数
    var lastModelUsageReading: [String: TokenTally]?
    var contextWindowSize = UsageTracker.defaultContextWindow
    var contextWindowAuthoritative = false
    /// 最近一次助手回合的用量与总量
    var lastAssistantUsage: TokenTally?
    var lastAssistantTotal: Int?
    var lastAssistantModel: String?
    var contextUsedTokens = 0
    var lastTotalCostUsd: Double?

    /// 供 `prompt` 响应使用的 `usage` 对象。
    var promptUsage: JSONValue {
        ["inputTokens": .int(accumulated.input), "outputTokens": .int(accumulated.output), "cachedReadTokens": .int(accumulated.cacheRead),
         "cachedWriteTokens": .int(accumulated.cacheWrite), "totalTokens": .int(accumulated.total)]
    }

    /// `_meta.quota`:总量与按模型明细。
    var quotaMeta: JSONValue {
        let rows = accumulatedByModel.sorted { $0.key < $1.key }.map { JSONValue(["model": .string($0.key), "token_count": $0.value.quotaJSON]) }
        return ["quota": ["token_count": accumulated.quotaJSON, "model_usage": .array(rows)]]
    }

    /// 读取 `modelUsage` 对象。
    static func normalize(_ modelUsage: JSONValue?) -> [String: TokenTally] {
        (modelUsage?.objectValue ?? [:]).mapValues { TokenTally(modelUsage: $0) }
    }

    /// 本次读数相对上次的增量(计数回退时视为重置,取当前值)。
    static func increment(current: [String: TokenTally], previous: [String: TokenTally]) -> [String: TokenTally] {
        var result: [String: TokenTally] = [:]
        for (model, usage) in current {
            var resolved = usage
            if let base = previous[model] {
                let diff = usage - base
                resolved = diff.hasNegative ? usage : diff
            }
            if resolved.total > 0 { result[model] = resolved }
        }
        return result
    }

    /// 在 `modelUsage` 的键里找与当前模型名公共前缀最长者。
    static func matchingModelUsage(_ modelUsage: JSONValue?, model: String) -> (key: String, usage: JSONValue)? {
        var bestKey: String?
        var bestLength = 0
        for key in (modelUsage?.objectValue ?? [:]).keys.sorted() {
            let length = zip(key, model).prefix { $0 == $1 }.count
            if length > bestLength { bestLength = length; bestKey = key }
        }
        guard let bestKey, let usage = modelUsage?[bestKey] else { return nil }
        return (bestKey, usage)
    }

    /// 处理一条非自治 `result`:更新累计、按模型统计与上下文窗口。
    /// - Returns: 本次结果的按模型增量
    mutating func recordResult(_ message: JSONValue, autonomous: Bool) -> [String: TokenTally] {
        if !autonomous { accumulated = accumulated + TokenTally(usage: message["usage"]) }
        let matching = lastAssistantModel.flatMap { Self.matchingModelUsage(message["modelUsage"], model: $0) }
        let reading = Self.normalize(message["modelUsage"])
        let increment: [String: TokenTally]
        if let previous = lastModelUsageReading {
            increment = Self.increment(current: reading, previous: previous)
        } else {
            let key = matching?.key ?? lastAssistantModel
            let row = TokenTally(usage: message["usage"])
            increment = (key != nil && row.total > 0) ? [key ?? "": row] : [:]
        }
        lastModelUsageReading = reading
        if !autonomous {
            for (model, usage) in increment { accumulatedByModel[model] = (accumulatedByModel[model] ?? TokenTally()) + usage }
        }
        if let matching, let window = matching.usage["contextWindow"]?.intValue, window > 0 {
            contextWindowSize = window
            contextWindowAuthoritative = true
        }
        lastTotalCostUsd = message["total_cost_usd"]?.doubleValue
        return increment
    }
}

private extension JSONValue {
    init(_ object: [String: JSONValue]) { self = .object(object) }
}
