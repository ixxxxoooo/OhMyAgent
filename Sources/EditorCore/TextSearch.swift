// @author ixxxxoooo
// 文本搜索:在 rope 上按行对齐的窗口里做字面/正则/整词/大小写搜索,不需要把整份大文件转成字符串。
// 供「选中下一个相同项(⌘D)」「全选相同项」与查找替换小部件共用。

import Foundation

/// 搜索选项。
public struct SearchOptions: Sendable, Equatable {
    /// 区分大小写。
    public var caseSensitive: Bool
    /// 整词匹配。
    public var wholeWord: Bool
    /// 以正则表达式解释模式。
    public var regex: Bool

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

/// rope 上的搜索。
public enum TextSearch {
    /// 单窗口的目标大小(UTF-16 单元)。
    static let windowSize = 512 * 1024
    /// 跨行模式一次性处理的上限(更大的文档退回按窗口搜索)。
    static let multilineLimit = 16 * 1024 * 1024

    /// 编译模式;非法正则返回 nil。
    public static func compile(_ pattern: String, options: SearchOptions) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        var source = options.regex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if options.wholeWord { source = "(?<![\\p{L}\\p{N}_])(?:" + source + ")(?![\\p{L}\\p{N}_])" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: source, options: flags)
    }

    /// 模式是否可能跨行匹配(决定窗口策略)。
    static func isMultiline(_ pattern: String, options: SearchOptions) -> Bool {
        if pattern.contains("\n") { return true }
        guard options.regex else { return false }
        return pattern.contains("\\n") || pattern.contains("\\s") || pattern.contains("[^") || pattern.contains("\\r")
    }

    /// 范围内的全部匹配(升序,零长匹配忽略)。
    /// - Parameters:
    ///   - rope: 文本
    ///   - pattern: 模式
    ///   - options: 选项
    ///   - range: 搜索范围,默认全文
    ///   - limit: 最多返回的匹配数
    public static func matches(
        in rope: TextRope, pattern: String, options: SearchOptions = SearchOptions(),
        range: TextSpan? = nil, limit: Int = 200_000
    ) -> [TextSpan] {
        guard let regex = compile(pattern, options: options) else { return [] }
        let scope = range ?? TextSpan(location: 0, length: rope.length)
        guard scope.length > 0 else { return [] }
        var result: [TextSpan] = []
        for window in windows(in: rope, scope: scope, multiline: isMultiline(pattern, options: options)) {
            let text = rope.string(in: window)
            let ns = text as NSString
            regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
                guard let match, match.range.length > 0 else { return }
                result.append(TextSpan(location: window.location + match.range.location, length: match.range.length))
                if result.count >= limit { stop.pointee = true }
            }
            if result.count >= limit { break }
        }
        return result
    }

    /// 自 `offset` 起向前/向后的第一个匹配;`wrap` 为真时到头后回绕。
    public static func next(
        in rope: TextRope, pattern: String, options: SearchOptions = SearchOptions(),
        from offset: Int, backward: Bool = false, wrap: Bool = true
    ) -> TextSpan? {
        let clamped = min(max(offset, 0), rope.length)
        if !backward {
            let tail = TextSpan(lower: clamped, upper: rope.length)
            if let hit = matches(in: rope, pattern: pattern, options: options, range: tail, limit: 1).first { return hit }
            guard wrap else { return nil }
            return matches(in: rope, pattern: pattern, options: options, range: TextSpan(lower: 0, upper: min(rope.length, clamped + patternSlack(pattern))), limit: 1).first
        }
        if let hit = lastMatch(in: rope, pattern: pattern, options: options, range: TextSpan(lower: 0, upper: clamped)) { return hit }
        guard wrap else { return nil }
        return lastMatch(in: rope, pattern: pattern, options: options, range: TextSpan(lower: clamped, upper: rope.length))
    }

    /// 回绕时多看几个字符,避免漏掉恰好跨越起点的匹配。
    private static func patternSlack(_ pattern: String) -> Int { pattern.utf16.count }

    /// 范围内的最后一个匹配(从后向前按窗口找)。
    static func lastMatch(in rope: TextRope, pattern: String, options: SearchOptions, range: TextSpan) -> TextSpan? {
        guard let regex = compile(pattern, options: options), range.length > 0 else { return nil }
        let wins = windows(in: rope, scope: range, multiline: isMultiline(pattern, options: options))
        for window in wins.reversed() {
            let text = rope.string(in: window)
            let ns = text as NSString
            var found: NSRange?
            regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                if let match, match.range.length > 0 { found = match.range }
            }
            if let found { return TextSpan(location: window.location + found.location, length: found.length) }
        }
        return nil
    }

    /// 把范围切成按行对齐的窗口;跨行模式尽量使用单个窗口。
    static func windows(in rope: TextRope, scope: TextSpan, multiline: Bool) -> [TextSpan] {
        if multiline && scope.length <= multilineLimit { return [scope] }
        var result: [TextSpan] = []
        var start = scope.location
        while start < scope.upperBound {
            var end = min(start + windowSize, scope.upperBound)
            if end < scope.upperBound {
                let line = rope.line(containing: end)
                end = line + 1 < rope.lineCount ? rope.lineStart(line + 1) : rope.length
                end = min(max(end, start + 1), scope.upperBound)
            }
            result.append(TextSpan(lower: start, upper: end))
            start = end
        }
        return result
    }
}
