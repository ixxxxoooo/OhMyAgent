// @author ixxxxoooo
// Markdown 就地渲染的解析层(纯函数,可在后台线程运行):
// 把文本切成「块」(标题、段落、引用、列表、围栏代码、表格、分隔线、前置元数据),
// 并为每个块产出内联片段(加粗/斜体/删除线/行内代码/链接/语法标记符)。
// 所有范围均为 UTF-16 偏移,与 NSTextStorage 一致。样式的落地见 `CodeEditorView+Markdown.swift`。

import Foundation

/// 块种类(决定块的基础字体与排版)。
public enum MarkdownLiveBlockKind: Sendable, Equatable {
    case paragraph
    case heading(Int)
    case quote
    case list
    case code(language: String?)
    case table
    case rule
    case frontMatter
    /// HTML 注释块(`<!-- … -->`,可含空行):预览里隐藏,源码里淡色显示
    case htmlComment
}

/// 内联字体特征。
public struct MarkdownLiveTraits: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold = MarkdownLiveTraits(rawValue: 1)
    public static let italic = MarkdownLiveTraits(rawValue: 2)
    public static let strike = MarkdownLiveTraits(rawValue: 4)
}

/// 内联/标记片段的样式。
public enum MarkdownLiveStyle: Sendable, Equatable {
    /// 加粗/斜体/删除线(可组合)
    case traits(MarkdownLiveTraits)
    /// 行内代码
    case inlineCode
    /// 链接文字
    case link
    /// 语法标记符(`#`、`**`、`` ` ``、`>`、围栏等):非活动块折叠,活动块淡色显示
    case marker
    /// 链接尾部 `](url)`:与标记符相同处理
    case linkTail
    /// 列表符号(始终可见,强调色)
    case listMarker
    /// 任务框 `[ ]` / `[x]`
    case taskBox(checked: Bool)
    /// 围栏代码内的语法色
    case codeToken(SyntaxKind)
    /// 次要信息(围栏语言名、表格分隔行、表格竖线)
    case dim
    /// 表头文字
    case tableHeader
}

/// 一个片段。
public struct MarkdownLiveSpan: Sendable, Equatable {
    public var range: NSRange
    public var style: MarkdownLiveStyle
}

/// 一个块。
public struct MarkdownLiveBlock: Sendable, Equatable {
    public var kind: MarkdownLiveBlockKind
    /// 块范围(含行尾换行)
    public var range: NSRange
    public var spans: [MarkdownLiveSpan]
}

/// 整篇文档的块布局。
public struct MarkdownLiveLayout: Sendable, Equatable {
    public var blocks: [MarkdownLiveBlock]
    public var length: Int

    /// 包含(或最接近)某偏移的块下标;落在块之间的空行返回 nil。
    /// - Parameter offset: UTF-16 偏移
    public func blockIndex(containing offset: Int) -> Int? {
        var low = 0, high = blocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = blocks[mid].range
            if offset < range.location { high = mid - 1 }
            else if offset >= NSMaxRange(range) {
                // 光标在块的末尾(例如最后一行没有换行)也算在块内
                if offset == NSMaxRange(range), offset == length { return mid }
                low = mid + 1
            } else { return mid }
        }
        return nil
    }
}

/// Markdown 解析器。
public enum MarkdownLiveRenderer {
    /// 超过该长度不做就地渲染(退化为普通文本)。
    public static let maxLength = 400_000

    /// 解析整篇文本。
    /// - Parameter text: 文本
    /// - Returns: 块布局
    public static func layout(for text: String) -> MarkdownLiveLayout {
        let ns = text as NSString
        let total = ns.length
        guard total > 0, total <= maxLength else { return MarkdownLiveLayout(blocks: [], length: total) }
        var parser = Parser(ns: ns)
        parser.run()
        return MarkdownLiveLayout(blocks: parser.blocks, length: total)
    }

    // MARK: 块级解析

    private struct Line {
        var full: NSRange      // 含换行
        var content: NSRange   // 不含换行
    }

    private struct Parser {
        let ns: NSString
        var lines: [Line] = []
        var blocks: [MarkdownLiveBlock] = []

        init(ns: NSString) {
            self.ns = ns
            var location = 0
            while location < ns.length {
                let full = ns.lineRange(for: NSRange(location: location, length: 0))
                var contentEnd = NSMaxRange(full)
                while contentEnd > full.location, isNewline(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
                lines.append(Line(full: full, content: NSRange(location: full.location, length: contentEnd - full.location)))
                location = NSMaxRange(full)
            }
        }

        func text(_ range: NSRange) -> String { ns.substring(with: range) }

        mutating func run() {
            var i = 0
            // 前置元数据
            if let first = lines.first, text(first.content) == "---" {
                var j = 1
                while j < lines.count, text(lines[j].content) != "---" { j += 1 }
                if j < lines.count {
                    emit(.frontMatter, lines: 0...j, spans: [])
                    i = j + 1
                }
            }
            while i < lines.count {
                let line = lines[i]
                let content = text(line.content)
                if isBlank(content) { i += 1; continue }
                if content.trimmingCharacters(in: .whitespaces).hasPrefix("<!--") {
                    i = parseHtmlComment(from: i)
                } else if let fence = fenceInfo(content) {
                    i = parseFence(from: i, fence: fence)
                } else if let level = headingLevel(content) {
                    parseHeading(at: i, level: level)
                    i += 1
                } else if isRule(content) {
                    emit(.rule, lines: i...i, spans: [])
                    i += 1
                } else if content.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    i = parseQuote(from: i)
                } else if listMarker(content) != nil {
                    i = parseList(from: i)
                } else if i + 1 < lines.count, content.contains("|"), isTableSeparator(text(lines[i + 1].content)) {
                    i = parseTable(from: i)
                } else {
                    i = parseParagraph(from: i)
                }
            }
        }

        mutating func emit(_ kind: MarkdownLiveBlockKind, lines range: ClosedRange<Int>, spans: [MarkdownLiveSpan]) {
            let start = lines[range.lowerBound].full.location
            let end = NSMaxRange(lines[range.upperBound].full)
            blocks.append(MarkdownLiveBlock(kind: kind, range: NSRange(location: start, length: end - start), spans: spans))
        }

        /// HTML 注释块:从 `<!--` 行到含 `-->` 的行(未闭合则到文末),中间的空行也属于注释。
        /// - Parameter start: 起始行下标
        /// - Returns: 下一个待解析的行下标
        mutating func parseHtmlComment(from start: Int) -> Int {
            var end = start
            while end < lines.count - 1, !text(lines[end].content).contains("-->") { end += 1 }
            emit(.htmlComment, lines: start...end, spans: [])
            return end + 1
        }

        // 围栏代码
        struct Fence { var char: Character; var count: Int; var info: String; var markerLength: Int; var indent: Int }

        func fenceInfo(_ content: String) -> Fence? {
            let indent = content.prefix(while: { $0 == " " }).count
            guard indent <= 3 else { return nil }
            let rest = content.dropFirst(indent)
            guard let ch = rest.first, ch == "`" || ch == "~" else { return nil }
            let count = rest.prefix(while: { $0 == ch }).count
            guard count >= 3 else { return nil }
            let info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
            if ch == "`", info.contains("`") { return nil }
            return Fence(char: ch, count: count, info: info, markerLength: count, indent: indent)
        }

        mutating func parseFence(from start: Int, fence: Fence) -> Int {
            var spans: [MarkdownLiveSpan] = []
            let open = lines[start].content
            spans.append(MarkdownLiveSpan(range: NSRange(location: open.location + fence.indent, length: fence.markerLength), style: .marker))
            let language = fence.info.split(separator: " ").first.map(String.init)
            if !fence.info.isEmpty {
                let infoStart = open.location + fence.indent + fence.markerLength
                let infoLength = NSMaxRange(open) - infoStart
                if infoLength > 0 { spans.append(MarkdownLiveSpan(range: NSRange(location: infoStart, length: infoLength), style: .dim)) }
            }
            var j = start + 1
            var closed = false
            let syntax = SyntaxLanguage.fromFence(language)
            var codeRange: NSRange?
            while j < lines.count {
                let content = text(lines[j].content)
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                if let ch = trimmed.first, ch == fence.char, trimmed.count >= fence.count, trimmed.allSatisfy({ $0 == ch }) {
                    let leading = content.prefix(while: { $0 == " " }).count
                    spans.append(MarkdownLiveSpan(range: NSRange(location: lines[j].content.location + leading, length: trimmed.count), style: .marker))
                    closed = true
                    break
                }
                let r = lines[j].full
                codeRange = codeRange.map { NSUnionRange($0, r) } ?? r
                j += 1
            }
            // 围栏内的语法色
            if let codeRange, syntax != .plain, codeRange.length <= 60_000 {
                let code = ns.substring(with: codeRange)
                for token in SimpleLexer.lex(code, language: syntax) {
                    spans.append(MarkdownLiveSpan(range: NSRange(location: codeRange.location + token.location, length: token.length), style: .codeToken(token.kind)))
                }
            }
            let end = closed ? j : max(j - 1, start)
            emit(.code(language: language), lines: start...min(end, lines.count - 1), spans: spans)
            return end + 1
        }

        // 标题
        func headingLevel(_ content: String) -> Int? {
            let indent = content.prefix(while: { $0 == " " }).count
            guard indent <= 3 else { return nil }
            let rest = content.dropFirst(indent)
            let hashes = rest.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(hashes) else { return nil }
            let after = rest.dropFirst(hashes)
            guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
            return hashes
        }

        mutating func parseHeading(at index: Int, level: Int) {
            let line = lines[index]
            let content = text(line.content)
            let indent = content.prefix(while: { $0 == " " }).count
            var markerLength = indent + level
            let chars = Array(content.utf16)
            while markerLength < chars.count, chars[markerLength] == 0x20 || chars[markerLength] == 0x09 { markerLength += 1 }
            var spans = [MarkdownLiveSpan(range: NSRange(location: line.content.location, length: markerLength), style: .marker)]
            // 结尾的 # 装饰(`## 标题 ##`)
            var end = chars.count
            while end > markerLength, chars[end - 1] == 0x20 { end -= 1 }
            var trailing = end
            while trailing > markerLength, chars[trailing - 1] == 0x23 { trailing -= 1 }
            if trailing < end, trailing > markerLength, chars[trailing - 1] == 0x20 {
                spans.append(MarkdownLiveSpan(range: NSRange(location: line.content.location + trailing, length: chars.count - trailing), style: .marker))
                end = trailing
            }
            let inlineRange = NSRange(location: line.content.location + markerLength, length: max(end - markerLength, 0))
            spans += inlineSpans(in: inlineRange)
            emit(.heading(level), lines: index...index, spans: spans)
        }

        func isRule(_ content: String) -> Bool {
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard let ch = trimmed.first, ch == "-" || ch == "*" || ch == "_" else { return false }
            let marks = trimmed.filter { $0 == ch }.count
            return marks >= 3 && trimmed.allSatisfy { $0 == ch || $0 == " " }
        }

        // 引用
        mutating func parseQuote(from start: Int) -> Int {
            var j = start
            var spans: [MarkdownLiveSpan] = []
            while j < lines.count {
                let content = text(lines[j].content)
                guard content.trimmingCharacters(in: .whitespaces).hasPrefix(">") else { break }
                let chars = Array(content.utf16)
                var k = 0
                while k < chars.count, chars[k] == 0x20 { k += 1 }
                var markerEnd = k + 1
                if markerEnd < chars.count, chars[markerEnd] == 0x20 { markerEnd += 1 }
                spans.append(MarkdownLiveSpan(range: NSRange(location: lines[j].content.location + k, length: markerEnd - k), style: .marker))
                spans += inlineSpans(in: NSRange(location: lines[j].content.location + markerEnd, length: max(chars.count - markerEnd, 0)))
                j += 1
            }
            emit(.quote, lines: start...(j - 1), spans: spans)
            return j
        }

        // 列表
        /// `start`/`end` 相对行首:标记符起点、标记符及其后空格的终点。
        struct ListMarker { var start: Int; var markerLength: Int; var end: Int; var taskLength: Int; var checked: Bool }

        func listMarker(_ content: String) -> ListMarker? {
            let chars = Array(content.utf16)
            var i = 0
            while i < chars.count, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
            guard i < chars.count else { return nil }
            var end = i
            if chars[i] == 0x2D || chars[i] == 0x2A || chars[i] == 0x2B { end = i + 1 }
            else {
                while end < chars.count, chars[end] >= 0x30, chars[end] <= 0x39 { end += 1 }
                guard end > i, end - i <= 9, end < chars.count, chars[end] == 0x2E || chars[end] == 0x29 else { return nil }
                end += 1
            }
            guard end < chars.count, chars[end] == 0x20 || chars[end] == 0x09 else { return nil }
            var markerEnd = end
            while markerEnd < chars.count, chars[markerEnd] == 0x20 { markerEnd += 1 }
            // 任务框
            var taskLength = 0
            var checked = false
            if markerEnd + 2 < chars.count, chars[markerEnd] == 0x5B, chars[markerEnd + 2] == 0x5D,
               chars[markerEnd + 1] == 0x20 || chars[markerEnd + 1] == 0x78 || chars[markerEnd + 1] == 0x58,
               markerEnd + 3 >= chars.count || chars[markerEnd + 3] == 0x20 {
                taskLength = 3
                checked = chars[markerEnd + 1] != 0x20
            }
            return ListMarker(start: i, markerLength: end - i, end: markerEnd, taskLength: taskLength, checked: checked)
        }

        mutating func parseList(from start: Int) -> Int {
            var j = start
            var spans: [MarkdownLiveSpan] = []
            while j < lines.count {
                let content = text(lines[j].content)
                if isBlank(content) { break }
                let base = lines[j].content.location
                if let marker = listMarker(content) {
                    spans.append(MarkdownLiveSpan(range: NSRange(location: base + marker.start, length: marker.markerLength), style: .listMarker))
                    var textStart = marker.end
                    if marker.taskLength > 0 {
                        spans.append(MarkdownLiveSpan(range: NSRange(location: base + marker.end, length: marker.taskLength), style: .taskBox(checked: marker.checked)))
                        textStart = marker.end + marker.taskLength
                    }
                    spans += inlineSpans(in: NSRange(location: base + textStart, length: max(lines[j].content.length - textStart, 0)))
                } else if content.hasPrefix(" ") || content.hasPrefix("\t") {
                    spans += inlineSpans(in: lines[j].content)
                } else {
                    break
                }
                j += 1
            }
            emit(.list, lines: start...(j - 1), spans: spans)
            return j
        }

        // 表格
        func isTableSeparator(_ content: String) -> Bool {
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("-"), trimmed.contains("|") || trimmed.contains(":") else { return false }
            return trimmed.allSatisfy { "|-: ".contains($0) }
        }

        mutating func parseTable(from start: Int) -> Int {
            var spans: [MarkdownLiveSpan] = []
            var j = start
            while j < lines.count {
                let content = text(lines[j].content)
                if isBlank(content) || (!content.contains("|") && j > start) { break }
                let line = lines[j]
                if j == start + 1 {
                    spans.append(MarkdownLiveSpan(range: line.content, style: .dim))
                } else {
                    if j == start { spans.append(MarkdownLiveSpan(range: line.content, style: .tableHeader)) }
                    for (offset, unit) in content.utf16.enumerated() where unit == 0x7C {
                        spans.append(MarkdownLiveSpan(range: NSRange(location: line.content.location + offset, length: 1), style: .dim))
                    }
                }
                j += 1
            }
            emit(.table, lines: start...(j - 1), spans: spans)
            return j
        }

        // 段落
        mutating func parseParagraph(from start: Int) -> Int {
            var j = start
            var spans: [MarkdownLiveSpan] = []
            while j < lines.count {
                let content = text(lines[j].content)
                if isBlank(content) { break }
                if j > start, fenceInfo(content) != nil || headingLevel(content) != nil || isRule(content)
                    || content.trimmingCharacters(in: .whitespaces).hasPrefix(">") || listMarker(content) != nil
                    || content.trimmingCharacters(in: .whitespaces).hasPrefix("<!--") { break }
                spans += inlineSpans(in: lines[j].content)
                j += 1
            }
            emit(.paragraph, lines: start...(j - 1), spans: spans)
            return j
        }

        func isBlank(_ content: String) -> Bool { content.allSatisfy { $0 == " " || $0 == "\t" } }

        // MARK: 内联

        func inlineSpans(in range: NSRange) -> [MarkdownLiveSpan] {
            guard range.length > 0 else { return [] }
            var spans: [MarkdownLiveSpan] = []
            parseInline(range, traits: [], into: &spans)
            return spans
        }

        func parseInline(_ range: NSRange, traits: MarkdownLiveTraits, into spans: inout [MarkdownLiveSpan]) {
            let end = NSMaxRange(range)
            var i = range.location
            var plainStart = range.location

            func flush(_ upTo: Int) {
                if !traits.isEmpty, upTo > plainStart {
                    spans.append(MarkdownLiveSpan(range: NSRange(location: plainStart, length: upTo - plainStart), style: .traits(traits)))
                }
            }
            func ch(_ index: Int) -> unichar { ns.character(at: index) }

            while i < end {
                let c = ch(i)
                if c == 0x5C, i + 1 < end { i += 2; continue }  // 反斜杠转义
                if c == 0x60 { // 行内代码
                    var n = 1
                    while i + n < end, ch(i + n) == 0x60 { n += 1 }
                    var j = i + n
                    var found: Int?
                    while j < end {
                        if ch(j) == 0x60 {
                            var m = 1
                            while j + m < end, ch(j + m) == 0x60 { m += 1 }
                            if m == n { found = j; break }
                            j += m
                        } else { j += 1 }
                    }
                    if let close = found, close > i + n {
                        flush(i)
                        spans.append(MarkdownLiveSpan(range: NSRange(location: i, length: n), style: .marker))
                        spans.append(MarkdownLiveSpan(range: NSRange(location: i + n, length: close - i - n), style: .inlineCode))
                        spans.append(MarkdownLiveSpan(range: NSRange(location: close, length: n), style: .marker))
                        i = close + n
                        plainStart = i
                        continue
                    }
                    i += n
                    continue
                }
                if c == 0x5B || (c == 0x21 && i + 1 < end && ch(i + 1) == 0x5B) { // 链接 / 图片
                    let open = c == 0x21 ? i + 1 : i
                    if let (textEnd, urlEnd) = linkBounds(open: open, end: end) {
                        flush(i)
                        spans.append(MarkdownLiveSpan(range: NSRange(location: i, length: open + 1 - i), style: .marker))
                        let textRange = NSRange(location: open + 1, length: textEnd - open - 1)
                        spans.append(MarkdownLiveSpan(range: textRange, style: .link))
                        spans.append(MarkdownLiveSpan(range: NSRange(location: textEnd, length: urlEnd - textEnd), style: .linkTail))
                        i = urlEnd
                        plainStart = i
                        continue
                    }
                }
                if c == 0x68, matchesURLPrefix(at: i, end: end) { // 裸链接
                    var j = i
                    while j < end, !isURLTerminator(ch(j)) { j += 1 }
                    while j > i, [0x2E, 0x2C, 0x29, 0x3B, 0x21, 0x3F].contains(ch(j - 1)) { j -= 1 }
                    if j - i > 8 {
                        flush(i)
                        spans.append(MarkdownLiveSpan(range: NSRange(location: i, length: j - i), style: .link))
                        i = j
                        plainStart = i
                        continue
                    }
                }
                if c == 0x2A || c == 0x5F || c == 0x7E { // * _ ~
                    var n = 1
                    while i + n < end, ch(i + n) == c { n += 1 }
                    let allowed = c == 0x7E ? (n == 2) : (n <= 3)
                    if allowed, i + n < end, !isSpace(ch(i + n)), openerAllowed(at: i, char: c, in: range) {
                        if let close = findCloser(char: c, count: n, from: i + n, end: end) {
                            flush(i)
                            var added: MarkdownLiveTraits
                            switch (c, n) {
                            case (0x7E, _): added = .strike
                            case (_, 1): added = .italic
                            case (_, 2): added = .bold
                            default: added = [.bold, .italic]
                            }
                            spans.append(MarkdownLiveSpan(range: NSRange(location: i, length: n), style: .marker))
                            parseInline(NSRange(location: i + n, length: close - i - n), traits: traits.union(added), into: &spans)
                            spans.append(MarkdownLiveSpan(range: NSRange(location: close, length: n), style: .marker))
                            i = close + n
                            plainStart = i
                            continue
                        }
                    }
                    i += n
                    continue
                }
                i += 1
            }
            flush(end)
        }

        /// `_` 不在单词中间开启(避免 snake_case 被误判)。
        func openerAllowed(at index: Int, char: unichar, in range: NSRange) -> Bool {
            guard char == 0x5F, index > range.location else { return true }
            let previous = ns.character(at: index - 1)
            return !isWordChar(previous)
        }

        func findCloser(char: unichar, count: Int, from start: Int, end: Int) -> Int? {
            var j = start
            while j < end {
                let c = ns.character(at: j)
                if c == 0x5C { j += 2; continue }
                if c == 0x60 { // 跳过行内代码
                    var m = 1
                    while j + m < end, ns.character(at: j + m) == 0x60 { m += 1 }
                    var k = j + m
                    var skipped = false
                    while k < end {
                        if ns.character(at: k) == 0x60 {
                            var q = 1
                            while k + q < end, ns.character(at: k + q) == 0x60 { q += 1 }
                            if q == m { j = k + q; skipped = true; break }
                            k += q
                        } else { k += 1 }
                    }
                    if skipped { continue }
                    j += m
                    continue
                }
                if c == char {
                    var m = 1
                    while j + m < end, ns.character(at: j + m) == char { m += 1 }
                    if m >= count, j > start, !isSpace(ns.character(at: j - 1)) {
                        // 下划线闭合后不能紧跟单词字符
                        if char != 0x5F || j + count >= end || !isWordChar(ns.character(at: j + count)) { return j }
                    }
                    j += m
                    continue
                }
                j += 1
            }
            return nil
        }

        /// `[text](url)` 的边界:返回 `]` 的位置与 `)` 之后的位置。
        func linkBounds(open: Int, end: Int) -> (Int, Int)? {
            var depth = 0
            var j = open
            while j < end {
                let c = ns.character(at: j)
                if c == 0x5C { j += 2; continue }
                if c == 0x5B { depth += 1 }
                if c == 0x5D {
                    depth -= 1
                    if depth == 0 { break }
                }
                j += 1
            }
            guard j < end, j > open + 1, j + 1 < end, ns.character(at: j + 1) == 0x28 else { return nil }
            var k = j + 2
            var parens = 1
            while k < end {
                let c = ns.character(at: k)
                if c == 0x28 { parens += 1 }
                if c == 0x29 {
                    parens -= 1
                    if parens == 0 { return (j, k + 1) }
                }
                k += 1
            }
            return nil
        }

        func matchesURLPrefix(at index: Int, end: Int) -> Bool {
            for prefix in ["https://", "http://"] {
                let units = Array(prefix.utf16)
                if index + units.count <= end, units.enumerated().allSatisfy({ ns.character(at: index + $0.offset) == $0.element }) {
                    return index == 0 || !isWordChar(ns.character(at: index - 1))
                }
            }
            return false
        }

        func isURLTerminator(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x3C || c == 0x3E || c == 0x22 || c == 0x5D }
        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func isWordChar(_ c: unichar) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c > 0x7F
        }
    }

    private static func isNewline(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }
}
