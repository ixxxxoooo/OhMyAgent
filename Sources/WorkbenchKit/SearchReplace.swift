// @author ixxxxoooo
// 全局替换的纯逻辑:按搜索选项(区分大小写/全词/正则)在文本里批量替换,支持正则捕获组(`$1`)。
// 无 UI、无 I/O,便于测试;文件读写由调用方负责。

import Foundation

/// 替换结果。
public struct ReplaceResult: Equatable, Sendable {
    /// 替换后的文本
    public var text: String
    /// 替换次数
    public var count: Int
}

/// 全局替换。
public enum SearchReplace {
    /// 由搜索选项构造正则;查询为空或正则非法时返回 nil。
    /// - Parameter options: 搜索选项
    public static func regex(for options: SearchOptions) -> NSRegularExpression? {
        guard !options.query.isEmpty else { return nil }
        var pattern = options.isRegex ? options.query : NSRegularExpression.escapedPattern(for: options.query)
        if options.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: flags)
    }

    /// 替换文本中所有匹配。
    /// - Parameters:
    ///   - text: 原文本
    ///   - options: 搜索选项
    ///   - replacement: 替换内容(正则模式下可含 `$1` 等捕获组引用;非正则按字面量)
    /// - Returns: 替换结果;查询非法时原样返回、次数为 0
    public static func replaceAll(in text: String, options: SearchOptions, replacement: String) -> ReplaceResult {
        guard let regex = regex(for: options) else { return ReplaceResult(text: text, count: 0) }
        let range = NSRange(text.startIndex..., in: text)
        let count = regex.numberOfMatches(in: text, range: range)
        guard count > 0 else { return ReplaceResult(text: text, count: 0) }
        let template = options.isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        return ReplaceResult(text: regex.stringByReplacingMatches(in: text, range: range, withTemplate: template), count: count)
    }

    /// 只替换指定行(1 起始)上的匹配,用于「替换单条结果」。
    /// - Parameters:
    ///   - text: 原文本
    ///   - line: 行号(1 起始)
    ///   - options: 搜索选项
    ///   - replacement: 替换内容
    /// - Returns: 替换结果;行号越界返回原文本
    public static func replace(inLine line: Int, of text: String, options: SearchOptions, replacement: String) -> ReplaceResult {
        var lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return ReplaceResult(text: text, count: 0) }
        let result = replaceAll(in: lines[line - 1], options: options, replacement: replacement)
        guard result.count > 0 else { return ReplaceResult(text: text, count: 0) }
        lines[line - 1] = result.text
        return ReplaceResult(text: lines.joined(separator: "\n"), count: result.count)
    }
}
