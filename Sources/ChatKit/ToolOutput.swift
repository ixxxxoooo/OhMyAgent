// @author ixxxxoooo
// 命令/工具输出的展示前处理(纯逻辑):去掉适配器包裹的 Markdown 围栏、统计行数、保留末尾若干行。

import Foundation

/// 输出文本的整形结果。
public struct ToolOutputSlice: Equatable, Sendable {
    /// 用于展示的文本(最多保留末尾 `maxLines` 行)
    public var text: String
    /// 原始总行数
    public var totalLines: Int
    /// 因超出上限而省略的行数
    public var omittedLines: Int
}

/// 工具输出整形。
public enum ToolOutputText {
    /// 去掉整段输出外层的 Markdown 围栏(```console … ```)。
    /// Claude 适配器会把命令输出包成围栏代码块,直接展示会出现「```console」字样。
    /// - Parameter text: 原始输出
    /// - Returns: 去围栏后的文本;没有围栏时原样返回
    public static func stripFence(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 去掉首尾空行后再判断围栏
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard lines.count >= 2, let first = lines.first, let last = lines.last else { return text }
        let head = first.trimmingCharacters(in: .whitespaces)
        let tail = last.trimmingCharacters(in: .whitespaces)
        guard head.hasPrefix("```"), tail == "```", !head.dropFirst(3).contains("`") else { return text }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    /// 统计行数并只保留末尾 `maxLines` 行(命令输出的关键信息通常在末尾)。
    /// - Parameters:
    ///   - text: 输出文本
    ///   - maxLines: 展示上限(≥1)
    /// - Returns: 整形结果
    public static func tail(_ text: String, maxLines: Int) -> ToolOutputSlice {
        let limit = max(1, maxLines)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // 末尾换行不算多一行
        let total = (lines.last?.isEmpty == true && lines.count > 1) ? lines.count - 1 : lines.count
        guard total > limit else { return ToolOutputSlice(text: text, totalLines: total, omittedLines: 0) }
        let kept = lines.prefix(total).suffix(limit).joined(separator: "\n")
        return ToolOutputSlice(text: kept, totalLines: total, omittedLines: total - limit)
    }
}
