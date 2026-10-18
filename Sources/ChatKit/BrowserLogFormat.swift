// @author ixxxxoooo
// 浏览器日志的呈现(对齐 Cursor):日志很长时不把全部内容塞进上下文——写成文件,只返回总行数、最近一段预览和文件路径,
// 让 Agent 用搜索/读取按需查看。纯逻辑,文件由应用层写入。

import Foundation

/// 日志呈现。
public enum BrowserLogFormat {
    /// 不超过这个行数时直接全部返回。
    public static let inlineLimit = 60
    /// 超出后内联展示最近多少行作为预览。
    public static let previewCount = 30

    /// 是否需要把日志写成文件(超过内联上限)。
    /// - Parameter count: 日志行数
    public static func needsFile(_ count: Int) -> Bool { count > inlineLimit }

    /// 生成返回给模型的文本。
    /// - Parameters:
    ///   - lines: 全部日志行(旧 → 新)
    ///   - noun: 日志名称(如 `console messages`)
    ///   - empty: 没有日志时的文案
    ///   - filePath: 完整日志文件路径(`needsFile` 为 true 时必须已写入)
    /// - Returns: 文本
    public static func render(lines: [String], noun: String, empty: String, filePath: String?) -> String {
        guard !lines.isEmpty else { return empty }
        guard needsFile(lines.count), let filePath else { return lines.joined(separator: "\n") }
        let preview = lines.suffix(previewCount).joined(separator: "\n")
        return "\(lines.count) \(noun) recorded. Showing the latest \(previewCount); the full log (\(lines.count) lines) is saved at \(filePath) — "
            + "search or read that file for anything older instead of asking for it again.\n\(preview)"
    }

    /// 截断过长的载荷文本(给模型看的预览)。
    /// - Parameters:
    ///   - text: 原文
    ///   - limit: 最大字符数
    public static func clip(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "… (\(text.count - limit) more characters)" : text
    }
}
