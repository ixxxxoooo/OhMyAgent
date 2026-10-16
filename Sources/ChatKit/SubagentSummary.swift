// @author ixxxxoooo
// 子 Agent 的运行统计:用于子 Agent 标签底部的「结束后统计」。
// 工具调用次数取自其内部时间线;耗时优先取工具结果里的 `<usage>`,否则用条目的起止时间;
// token 只在结果文本带 `total_tokens` 时才有(没有就不显示,不做估算)。

import ACPKit
import Foundation

/// 子 Agent 运行统计。
public struct SubagentSummary: Sendable, Equatable {
    /// 内部工具调用次数(含嵌套子 Agent 内部)
    public var toolUses: Int
    /// 耗时(秒)
    public var durationSeconds: Double
    /// 总 token(结果里没有则为 nil)
    public var totalTokens: Int?
    /// 终态
    public var status: ToolStatus

    /// 展示用的片段,例如 `用时 1m 12s`、`12 次工具调用`、`3.4K tokens`。
    public var parts: [String] {
        var result = [String(localized: "用时 \(WorkingStatus.elapsed(Int(durationSeconds.rounded())))")]
        result.append(String(localized: "\(toolUses) 次工具调用"))
        if let totalTokens { result.append(String(localized: "\(Self.compact(totalTokens)) tokens")) }
        return result
    }

    /// 复制用文本。
    public var copyText: String { parts.joined(separator: " · ") }

    /// 由子 Agent 工具条目生成统计;条目没有工具调用信息时返回 nil。
    /// - Parameter entry: 子 Agent 的父工具条目
    /// - Returns: 统计(仅终态才有意义,运行中也可调用,耗时为当前已用时间)
    @MainActor
    public static func make(entry: TimelineEntry) -> SubagentSummary? {
        guard let tool = entry.tool else { return nil }
        let usage = parseUsage(from: resultText(of: tool))
        let counted = entry.childStore.map { countTools(in: $0) } ?? 0
        let duration = usage.durationMs.map { Double($0) / 1000 } ?? entry.elapsedSeconds
        return SubagentSummary(toolUses: usage.toolUses ?? counted, durationSeconds: duration, totalTokens: usage.totalTokens, status: tool.status)
    }

    /// 解析工具结果里的 `<usage>` 片段。
    /// - Parameter text: 结果文本
    /// - Returns: token、工具调用数与耗时(毫秒);缺失的字段为 nil
    public static func parseUsage(from text: String) -> (totalTokens: Int?, toolUses: Int?, durationMs: Int?) {
        func number(_ key: String) -> Int? {
            guard let range = text.range(of: key + ":") else { return nil }
            let digits = text[range.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
            return Int(digits)
        }
        return (number("total_tokens"), number("tool_uses"), number("duration_ms"))
    }

    /// 紧凑数字:`950`、`3.4K`、`1.2M`。
    public static func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fK", Double(value) / 1000) }
        return "\(value)"
    }

    private static func resultText(of tool: ToolCall) -> String {
        var pieces: [String] = []
        for item in tool.content {
            if case .content(.text(let text)) = item { pieces.append(text) }
        }
        if let raw = tool.rawOutput {
            if let text = raw.stringValue { pieces.append(text) }
            else if let array = raw.arrayValue { pieces.append(contentsOf: array.compactMap { $0["text"]?.stringValue }) }
            else if let text = raw["text"]?.stringValue { pieces.append(text) }
        }
        return pieces.joined(separator: "\n")
    }

    @MainActor
    private static func countTools(in store: TimelineStore) -> Int {
        store.entries.reduce(0) { total, entry in
            guard entry.kind == .tool else { return total }
            return total + 1 + (entry.childStore.map { countTools(in: $0) } ?? 0)
        }
    }
}
