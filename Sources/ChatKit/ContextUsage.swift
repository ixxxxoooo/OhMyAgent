// @author ixxxxoooo
// 上下文用量明细:解析 Claude Code 本地命令 `/context` 的 Markdown 输出,并提供圆环色调与兜底分类。
// ACP 的 `usage_update` 只有「已用 / 窗口」两个数,没有分类;分类明细来自 `/context`(不调用模型)。

import ACPKit
import Foundation

/// 上下文分类的性质(决定颜色与是否计入分段条)。
public enum ContextCategoryKind: Sendable, Hashable {
    /// 已占用(系统提示、工具定义、对话等)
    case used
    /// 剩余空间
    case free
    /// 自动压缩预留
    case buffer
}

/// 上下文分类行。
public struct ContextCategory: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var tokens: Int
    public var kind: ContextCategoryKind

    public init(name: String, tokens: Int, kind: ContextCategoryKind) {
        self.name = name
        self.tokens = tokens
        self.kind = kind
    }
}

/// 圆环色调:占用越高越醒目。
public enum ContextTone: Sendable, Hashable {
    case normal, warn, danger

    /// 转为「警告」色的占用比例
    public static let warnFraction = 0.8
    /// 转为「危险」色的占用比例
    public static let dangerFraction = 0.95

    /// 按占用比例取色调。
    /// - Parameter fraction: 0...1(可超过 1)
    public init(fraction: Double) {
        if fraction >= Self.dangerFraction { self = .danger } else if fraction >= Self.warnFraction { self = .warn } else { self = .normal }
    }
}

/// 上下文用量明细。
public struct ContextUsage: Sendable, Hashable {
    public var model: String
    public var totalTokens: Int
    public var maxTokens: Int
    public var categories: [ContextCategory]

    public init(model: String = "", totalTokens: Int, maxTokens: Int, categories: [ContextCategory] = []) {
        self.model = model
        self.totalTokens = totalTokens
        self.maxTokens = maxTokens
        self.categories = categories
    }

    /// 占用比例(0...1,窗口无效时为 0)。
    public var fraction: Double {
        maxTokens > 0 ? Double(max(0, totalTokens)) / Double(maxTokens) : 0
    }

    /// 紧凑 token 数:2400 → 2.4K,1_200_000 → 1.2M,小于 1000 原样。
    /// - Parameter tokens: token 数
    public static func formatTokens(_ tokens: Int) -> String {
        func trimmed(_ value: Double, _ suffix: String) -> String {
            let text = String(format: "%.1f", value)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        if tokens >= 1_000_000 { return trimmed(Double(tokens) / 1_000_000, "M") }
        if tokens >= 1_000 { return trimmed(Double(tokens) / 1_000, "K") }
        return "\(tokens)"
    }

    /// 占用百分比(四舍五入)。
    public var percent: Int { Int((fraction * 100).rounded()) }

    /// 圆环色调。
    public var tone: ContextTone { ContextTone(fraction: fraction) }

    /// 由 ACP `usage_update` 的「已用 / 窗口」合成两段明细(已用 + 剩余),面板没有分类时也有分段条可看。
    /// - Parameter usage: Agent 上报的用量;缺少已用或窗口时返回 nil
    public init?(reported usage: UsageUpdate) {
        guard let used = usage.used, let size = usage.size, size > 0 else { return nil }
        self.init(totalTokens: used, maxTokens: size, categories: [
            ContextCategory(name: ChatL10n.t("已用"), tokens: max(0, used), kind: .used),
            ContextCategory(name: ChatL10n.t("剩余"), tokens: max(0, size - used), kind: .free),
        ])
    }
}

/// `/context` 输出解析器。
public enum ContextUsageParser {
    /// 解析 `/context` 输出的完整 Markdown。
    ///
    /// 期望格式(来自真实抓取):
    ///
    ///     **Model:** claude-opus-5-5
    ///     **Tokens:** 38.6k / 1m (4%)
    ///     ### Estimated usage by category
    ///     | Category | Tokens | Percentage |
    ///     | System prompt | 1.9k | 0.2% |
    ///
    /// - Parameter text: 完整文本
    /// - Returns: 用量明细;缺少总量或分类表时返回 nil(由调用方降级)
    public static func parse(_ text: String) -> ContextUsage? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var model = ""
        var totals: (Int, Int)?
        var categories: [ContextCategory] = []
        var inTable = false
        var seenHeading = false
        for line in lines {
            if let value = value(after: "**Model:**", in: line) { model = value; continue }
            if let value = value(after: "**Tokens:**", in: line) { totals = parseTotals(value); continue }
            if line.hasPrefix("#") {
                if inTable { break }
                seenHeading = line.lowercased().contains("by category")
                continue
            }
            guard seenHeading else { continue }
            if line.isEmpty {
                if !categories.isEmpty { inTable = false; break }
                continue
            }
            guard line.hasPrefix("|") else { continue }
            inTable = true
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            // 表头与分隔行的第二列不是数量,自然被跳过
            guard cells.count >= 2, let tokens = parseTokenCount(cells[1]) else { continue }
            categories.append(ContextCategory(name: cells[0], tokens: tokens, kind: kind(of: cells[0])))
        }
        guard let totals, totals.1 > 0, !categories.isEmpty else { return nil }
        return ContextUsage(model: model, totalTokens: totals.0, maxTokens: totals.1, categories: categories)
    }

    /// 解析「1.9k / 34.7k / 1m / ~480 / 512」这类简写 token 数。
    /// - Parameter raw: 文本
    /// - Returns: token 数;无法解析为 nil
    public static func parseTokenCount(_ raw: String) -> Int? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("~") { text.removeFirst() }
        var factor = 1.0
        if let last = text.last, "kKmM".contains(last) {
            factor = "kK".contains(last) ? 1_000 : 1_000_000
            text.removeLast()
        }
        guard !text.isEmpty, let value = Double(text.replacingOccurrences(of: ",", with: "")), value.isFinite, value >= 0 else { return nil }
        return Int((value * factor).rounded())
    }

    /// 按名称判定分类性质。
    private static func kind(of name: String) -> ContextCategoryKind {
        let lower = name.lowercased()
        if lower == "free space" { return .free }
        if lower.contains("autocompact buffer") { return .buffer }
        return .used
    }

    /// 取 `**Key:**` 之后的值。
    private static func value(after key: String, in line: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        return line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
    }

    /// 解析「38.6k / 1m (4%)」。
    private static func parseTotals(_ value: String) -> (Int, Int)? {
        let parts = value.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let used = parseTokenCount(parts[0]) else { return nil }
        let maxText = parts[1].split(separator: " ").first.map(String.init) ?? parts[1]
        guard let size = parseTokenCount(maxText) else { return nil }
        return (used, size)
    }
}

/// 上下文优化建议。
public enum ContextHint: Sendable, Hashable {
    /// MCP 工具定义占用窗口的比例(百分比,四舍五入)偏高,可开启按需加载或停用不常用服务器
    case mcpHeavy(percent: Int)
    /// 总占用接近上限,建议压缩或开新会话
    case nearFull(percent: Int)
}

/// 上下文优化建议生成(纯逻辑)。
public enum ContextAdvisor {
    /// MCP 工具占比超过该值(窗口的 10%,与 Claude Code 自动启用工具搜索的阈值一致)时给出建议
    public static let mcpThreshold = 0.10

    /// 按分类明细给出优化建议。
    /// - Parameter usage: 上下文用量明细
    /// - Returns: 建议列表(可能为空),按重要性排序
    public static func hints(for usage: ContextUsage) -> [ContextHint] {
        guard usage.maxTokens > 0 else { return [] }
        var result: [ContextHint] = []
        let mcpTokens = usage.categories
            .filter { $0.kind == .used && $0.name.lowercased().contains("mcp") }
            .reduce(0) { $0 + $1.tokens }
        let mcpFraction = Double(mcpTokens) / Double(usage.maxTokens)
        if mcpFraction > mcpThreshold { result.append(.mcpHeavy(percent: Int((mcpFraction * 100).rounded()))) }
        if usage.fraction >= ContextTone.warnFraction { result.append(.nearFull(percent: usage.percent)) }
        return result
    }
}
