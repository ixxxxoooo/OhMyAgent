// @author ixxxxoooo
// 编辑器文本编辑命令(纯函数,无 UI):行注释切换、上下移动行、复制行、删除行、缩进/反缩进、
// 回车自动缩进、括号与引号自动闭合/跨越、括号匹配、行号定位。
// 全部基于 UTF-16 范围(与 NSTextView 一致);返回 `TextEdit`,由视图用「询问 → 替换 → 通知」流程应用,撤销栈因此正常工作。

import Foundation

/// 一次文本编辑:替换 `range` 为 `replacement`,之后把选区设为 `selection`(替换后的文本坐标)。
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    /// - Parameters:
    ///   - range: 被替换的范围
    ///   - replacement: 替换文本
    ///   - selection: 替换后的选区
    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

public enum EditorEditing {
    // MARK: 行范围

    /// 选区覆盖的整行范围;选区非空且恰好止于下一行行首时,不把下一行算进去。
    /// - Parameters:
    ///   - text: 全文
    ///   - selection: 选区
    public static func coveredLines(in text: String, selection: NSRange) -> NSRange {
        let ns = text as NSString
        let location = min(max(selection.location, 0), ns.length)
        var end = min(location + max(selection.length, 0), ns.length)
        if end > location, ns.character(at: end - 1) == 10 { end -= 1 }
        return ns.lineRange(for: NSRange(location: location, length: end - location))
    }

    /// 某一行(1 起始)的完整范围(含换行);越界返回 nil。
    /// - Parameters:
    ///   - line: 行号(1 起始)
    ///   - text: 全文
    public static func range(ofLine line: Int, in text: String) -> NSRange? {
        guard line >= 1 else { return nil }
        let ns = text as NSString
        var current = 1
        var location = 0
        while current < line {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(range)
            if next >= ns.length || next == location { return nil }
            location = next
            current += 1
        }
        return ns.lineRange(for: NSRange(location: location, length: 0))
    }

    // MARK: 行注释

    /// 语言对应的行注释前缀;没有行注释的语言(JSON、Markdown、纯文本)返回 nil。
    /// - Parameter language: 语言
    public static func commentPrefix(for language: SyntaxLanguage) -> String? {
        switch language {
        case .swift, .javascript, .typescript, .rust, .go, .java, .c, .php: return "//"
        case .python, .shell, .yaml, .ruby, .toml, .dockerfile: return "#"
        case .sql, .lua: return "--"
        case .json, .markdown, .html, .css, .plain: return nil
        }
    }

    /// 切换选区所在行的注释:所有非空行都已注释则取消,否则统一加注释(在最小缩进列处插入)。
    /// - Parameters:
    ///   - text: 全文
    ///   - selection: 选区
    ///   - prefix: 注释前缀(如 `//`)
    /// - Returns: 编辑;选区行全为空行时返回 nil
    public static func toggleLineComment(text: String, selection: NSRange, prefix: String) -> TextEdit? {
        guard !prefix.isEmpty else { return nil }
        let ns = text as NSString
        let block = coveredLines(in: text, selection: selection)
        let lines = splitLines(ns.substring(with: block))
        let nonBlank = lines.indices.filter { !lines[$0].content.allSatisfy { $0 == " " || $0 == "\t" } }
        guard !nonBlank.isEmpty else { return nil }
        let allCommented = nonBlank.allSatisfy { lines[$0].content.drop { $0 == " " || $0 == "\t" }.hasPrefix(prefix) }
        var result = lines
        var deltas = [Int](repeating: 0, count: lines.count)
        if allCommented {
            for index in nonBlank {
                let content = lines[index].content
                let indentCount = content.prefix { $0 == " " || $0 == "\t" }.count
                var rest = String(content.dropFirst(indentCount + prefix.count))
                if rest.hasPrefix(" ") { rest.removeFirst() }
                let new = String(content.prefix(indentCount)) + rest
                deltas[index] = new.utf16.count - content.utf16.count
                result[index].content = new
            }
        } else {
            let column = nonBlank.map { lines[$0].content.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            for index in nonBlank {
                let content = lines[index].content
                let head = content.prefix(column)
                let new = String(head) + prefix + " " + String(content.dropFirst(column))
                deltas[index] = new.utf16.count - content.utf16.count
                result[index].content = new
            }
        }
        let replacement = result.map { $0.content + $0.terminator }.joined()
        // 选区跟随:起点按所在行的变化平移,长度吸收其余变化
        let firstDelta = deltas.first ?? 0
        let total = deltas.reduce(0, +)
        let location = max(block.location, selection.location + firstDelta)
        let length = max(0, selection.length + total - firstDelta)
        return TextEdit(range: block, replacement: replacement, selection: NSRange(location: location, length: length))
    }

    // MARK: 移动与复制

    /// 把选区所在的行整体上移或下移一行。
    /// - Parameters:
    ///   - text: 全文
    ///   - selection: 选区
    ///   - up: true 上移,false 下移
    /// - Returns: 编辑;已在首行/末行返回 nil
    public static func moveLines(text: String, selection: NSRange, up: Bool) -> TextEdit? {
        let ns = text as NSString
        let block = coveredLines(in: text, selection: selection)
        if up {
            guard block.location > 0 else { return nil }
            let previous = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let region = NSRange(location: previous.location, length: NSMaxRange(block) - previous.location)
            let blockLines = splitLines(ns.substring(with: block))
            let prevLines = splitLines(ns.substring(with: previous))
            let replacement = joined(blockLines + prevLines, lastHasTerminator: lastHasTerminator(ns.substring(with: block)))
            let shifted = NSRange(location: selection.location - previous.length, length: selection.length)
            return TextEdit(range: region, replacement: replacement, selection: shifted)
        } else {
            guard NSMaxRange(block) < ns.length else { return nil }
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            let region = NSRange(location: block.location, length: NSMaxRange(next) - block.location)
            let blockLines = splitLines(ns.substring(with: block))
            let nextLines = splitLines(ns.substring(with: next))
            let replacement = joined(nextLines + blockLines, lastHasTerminator: lastHasTerminator(ns.substring(with: next)))
            let shifted = NSRange(location: selection.location + next.length, length: selection.length)
            return TextEdit(range: region, replacement: replacement, selection: shifted)
        }
    }

    /// 复制选区所在的行。
    /// - Parameters:
    ///   - text: 全文
    ///   - selection: 选区
    ///   - down: true 复制到下方(选区移到副本),false 复制到上方(选区留在原行)
    public static func duplicateLines(text: String, selection: NSRange, down: Bool) -> TextEdit {
        let ns = text as NSString
        let block = coveredLines(in: text, selection: selection)
        var content = ns.substring(with: block)
        let hadTerminator = content.hasSuffix("\n")
        if !hadTerminator { content += "\n" }
        if down {
            // 末行无换行时先补换行再插入副本
            let insertion = hadTerminator ? content : "\n" + String(content.dropLast())
            let shift = hadTerminator ? block.length : block.length + 1
            return TextEdit(range: NSRange(location: NSMaxRange(block), length: 0), replacement: insertion,
                            selection: NSRange(location: selection.location + shift, length: selection.length))
        }
        return TextEdit(range: NSRange(location: block.location, length: 0), replacement: content, selection: selection)
    }

    /// 删除选区所在的整行。
    /// - Parameters:
    ///   - text: 全文
    ///   - selection: 选区
    public static func deleteLines(text: String, selection: NSRange) -> TextEdit {
        let block = coveredLines(in: text, selection: selection)
        return TextEdit(range: block, replacement: "", selection: NSRange(location: block.location, length: 0))
    }

    // MARK: 缩进

    /// 语言惯用的一级缩进:前端/配置类两个空格,其余四个空格。
    /// - Parameter language: 语言
    public static func indentUnit(for language: SyntaxLanguage) -> String {
        switch language {
        case .javascript, .typescript, .json, .yaml, .html, .css, .ruby, .lua, .toml: return "  "
        default: return "    "
        }
    }

    /// 多行选区的缩进/反缩进(单行无选区的 Tab 由系统处理)。
    /// - Parameters:
    ///   - text: 全文
    ///   - selection: 选区
    ///   - outdent: true 反缩进
    ///   - unit: 一级缩进(如四个空格或一个制表符)
    /// - Returns: 编辑;没有可变化的行返回 nil
    public static func indent(text: String, selection: NSRange, outdent: Bool, unit: String) -> TextEdit? {
        guard !unit.isEmpty else { return nil }
        let ns = text as NSString
        let block = coveredLines(in: text, selection: selection)
        let lines = splitLines(ns.substring(with: block))
        var result = lines
        var firstDelta = 0
        var total = 0
        for (index, line) in lines.enumerated() {
            let content = line.content
            var new = content
            if outdent {
                if content.hasPrefix("\t") { new = String(content.dropFirst()) }
                else {
                    let spaces = content.prefix { $0 == " " }.count
                    new = String(content.dropFirst(min(spaces, unit.count)))
                }
            } else if !content.isEmpty {
                new = unit + content
            }
            let delta = new.utf16.count - content.utf16.count
            if index == 0 { firstDelta = delta }
            total += delta
            result[index].content = new
        }
        guard total != 0 else { return nil }
        let replacement = result.map { $0.content + $0.terminator }.joined()
        let location = max(block.location, selection.location + firstDelta)
        return TextEdit(range: block, replacement: replacement, selection: NSRange(location: location, length: max(0, selection.length + total - firstDelta)))
    }

    // MARK: 回车自动缩进

    /// 回车处的自动缩进:沿用当前行缩进;行尾是 `{ ( [`(或 Python 的 `:`)时多缩一级;
    /// 光标恰在 `{|}` 之间时拆成三行并把光标放在中间行。
    /// - Parameters:
    ///   - text: 全文
    ///   - caret: 光标(UTF-16 偏移)
    ///   - unit: 一级缩进
    ///   - language: 语言(决定 `:` 是否开块)
    /// - Returns: 要插入的文本与光标在其中的偏移
    public static func newline(text: String, caret: Int, unit: String, language: SyntaxLanguage = .plain) -> (insertion: String, caret: Int) {
        let ns = text as NSString
        let offset = min(max(caret, 0), ns.length)
        let line = ns.lineRange(for: NSRange(location: offset, length: 0))
        let head = ns.substring(with: NSRange(location: line.location, length: offset - line.location))
        let indent = String(head.prefix { $0 == " " || $0 == "\t" })
        let trimmedHead = head.reversed().drop { $0 == " " || $0 == "\t" }
        let before = trimmedHead.first
        let after = character(in: ns, at: offset)
        let opens: Set<Character> = ["{", "(", "["]
        let opensBlock = before.map { opens.contains($0) || ($0 == ":" && language == .python) } ?? false
        let closers: [Character: Character] = ["{": "}", "(": ")", "[": "]"]
        if let before, let after, closers[before] == after {
            let inner = "\n" + indent + unit
            return (inner + "\n" + indent, inner.utf16.count)
        }
        let extra = opensBlock ? unit : ""
        let insertion = "\n" + indent + extra
        return (insertion, insertion.utf16.count)
    }

    // MARK: 自动闭合

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]

    /// 输入一个字符时的自动闭合/包裹/跨越处理。
    /// - Parameters:
    ///   - typed: 输入的字符
    ///   - text: 全文
    ///   - selection: 选区
    /// - Returns: 需要代替默认插入的编辑;不处理(按普通字符插入)返回 nil
    public static func typed(_ typed: Character, text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let location = min(max(selection.location, 0), ns.length)
        // 选区非空且输入的是开括号/引号:包裹选区
        if selection.length > 0, let closer = pairs[typed] {
            let inner = ns.substring(with: selection)
            return TextEdit(range: selection, replacement: String(typed) + inner + String(closer),
                            selection: NSRange(location: location + 1, length: selection.length))
        }
        guard selection.length == 0 else { return nil }
        let next = character(in: ns, at: location)
        let previous = character(in: ns, at: location - 1)
        // 输入闭合符且光标后正是同一个符号:跨越
        if let next, next == typed, pairs.values.contains(typed) {
            return TextEdit(range: NSRange(location: location, length: 0), replacement: "", selection: NSRange(location: location + 1, length: 0))
        }
        guard let closer = pairs[typed] else { return nil }
        let isQuote = typed == "\"" || typed == "'" || typed == "`"
        // 光标后只有空白、结尾或闭合符时才自动闭合
        let nextOK = next == nil || next == " " || next == "\n" || next == "\t" || next.map { ")]}".contains($0) } == true
        guard nextOK else { return nil }
        // 引号紧跟在字母数字后(如 don't)不闭合
        if isQuote, let previous, previous.isLetter || previous.isNumber { return nil }
        return TextEdit(range: NSRange(location: location, length: 0), replacement: String(typed) + String(closer),
                        selection: NSRange(location: location + 1, length: 0))
    }

    /// 退格时若光标夹在一对空括号/引号之间,一并删除两个符号。
    /// - Parameters:
    ///   - text: 全文
    ///   - selection: 选区
    public static func backspacePair(text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        guard selection.length == 0, selection.location > 0, selection.location < ns.length,
              let open = character(in: ns, at: selection.location - 1),
              let close = character(in: ns, at: selection.location),
              pairs[open] == close else { return nil }
        return TextEdit(range: NSRange(location: selection.location - 1, length: 2), replacement: "",
                        selection: NSRange(location: selection.location - 1, length: 0))
    }

    // MARK: 括号匹配

    /// 查找光标处括号的配对括号(先看光标后一个字符,再看前一个)。扫描上限 20000 个字符,不处理字符串/注释里的括号。
    /// - Parameters:
    ///   - text: 全文
    ///   - offset: 光标偏移(UTF-16)
    /// - Returns: (开括号偏移, 闭括号偏移);没有匹配返回 nil
    public static func matchingBracket(in text: String, at offset: Int) -> (open: Int, close: Int)? {
        let ns = text as NSString
        let openers: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
        let closers: [unichar: unichar] = [41: 40, 93: 91, 125: 123]
        let limit = 20_000
        for candidate in [offset, offset - 1] where candidate >= 0 && candidate < ns.length {
            let char = ns.character(at: candidate)
            if let close = openers[char] {
                var depth = 0
                var index = candidate
                let end = min(ns.length, candidate + limit)
                while index < end {
                    let current = ns.character(at: index)
                    if current == char { depth += 1 } else if current == close { depth -= 1; if depth == 0 { return (candidate, index) } }
                    index += 1
                }
            } else if let open = closers[char] {
                var depth = 0
                var index = candidate
                let start = max(0, candidate - limit)
                while index >= start {
                    let current = ns.character(at: index)
                    if current == char { depth += 1 } else if current == open { depth -= 1; if depth == 0 { return (index, candidate) } }
                    index -= 1
                }
            }
        }
        return nil
    }

    // MARK: 内部

    /// 取某偏移处的字符(越界或代理项返回 nil)。
    private static func character(in ns: NSString, at index: Int) -> Character? {
        guard index >= 0, index < ns.length, let scalar = UnicodeScalar(ns.character(at: index)) else { return nil }
        return Character(scalar)
    }

    private struct Line {
        var content: String
        var terminator: String
    }

    /// 按换行拆成(内容, 行结束符)序列。
    private static func splitLines(_ text: String) -> [Line] {
        var lines: [Line] = []
        var current = ""
        for char in text {
            if char == "\n" { lines.append(Line(content: current, terminator: "\n")); current = "" }
            else { current.append(char) }
        }
        if !current.isEmpty || lines.isEmpty { lines.append(Line(content: current, terminator: "")) }
        return lines
    }

    private static func lastHasTerminator(_ text: String) -> Bool { text.hasSuffix("\n") }

    /// 拼接行;除最后一行外都补换行,最后一行按 `lastHasTerminator` 决定。
    private static func joined(_ lines: [Line], lastHasTerminator: Bool) -> String {
        var out = ""
        for (index, line) in lines.enumerated() {
            out += line.content
            if index < lines.count - 1 || lastHasTerminator { out += "\n" }
        }
        return out
    }
}
