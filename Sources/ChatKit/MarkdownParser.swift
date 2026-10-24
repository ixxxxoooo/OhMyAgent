// @author ixxxxoooo
// 轻量 Markdown 块级解析器:把文本切分为段落、标题、列表、引用、代码块、表格与分隔线。
// 行内语法(粗体、斜体、行内代码、链接)交给系统的 AttributedString(markdown:) 渲染。
// 流式输出时未闭合的代码围栏视为代码块直到文本结尾。

import Foundation

/// 列表项。
public struct MarkdownListItem: Hashable, Sendable {
    public var level: Int
    public var marker: String
    public var text: String
    public var checked: Bool?
}

/// 表格列对齐(来自分隔行 `:---` / `:---:` / `---:`)。
public enum MarkdownTableAlign: Hashable, Sendable {
    /// 未指定(按左对齐显示)
    case none
    case left
    case center
    case right
}

/// Markdown 块。
public enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String, isClosed: Bool)
    case list([MarkdownListItem])
    case quote(String)
    case table(header: [String], rows: [[String]], aligns: [MarkdownTableAlign])
    case rule
}

/// 一次解析的结果与续解析所需的信息(流式输出时,下一批文本只需重解析最后一个块)。
public struct MarkdownParseState: Sendable {
    /// 被解析的完整文本。
    public let text: String
    /// 块序列。
    public let blocks: [MarkdownBlock]
    /// 每个块起始行在 `text` 中的 UTF-8 偏移(与 `blocks` 等长)。
    let starts: [Int]
}

/// 块级解析入口。
public enum MarkdownParser {
    /// 解析 Markdown 文本。
    /// - Parameter text: 原始文本
    /// - Returns: 块序列
    public static func parse(_ text: String) -> [MarkdownBlock] {
        parseState(text).blocks
    }

    /// 统一换行为 `\n`。Swift 的 `String` 把 `\r\n` 当作单个字符,`split(separator: "\n")` 切不开 CRLF 文本
    /// (Windows 风格的 `.md` 会整篇退化成一个段落,标题、表格、列表全部失效);单独的 `\r`(旧 Mac)同理。
    /// - Parameter text: 原始文本
    /// - Returns: 只含 `\n` 换行的文本(没有 `\r` 时原样返回,不产生拷贝)
    static func normalizedNewlines(_ text: String) -> String {
        guard text.utf8.contains(13) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// 解析并保留续解析信息。
    /// - Parameter text: 原始文本
    public static func parseState(_ text: String) -> MarkdownParseState {
        let text = normalizedNewlines(text)
        let (blocks, starts) = parseCore(text)
        return MarkdownParseState(text: text, blocks: blocks, starts: starts)
    }

    /// 流式续解析:新文本以上次文本为前缀时,只重解析上次的最后两个块及其之后的内容。
    ///
    /// 正确性依据:解析器自左向右,每个块的起始行处解析器状态是干净的(没有未结束的段落),
    /// 因此从某个块的起始行重新解析,得到的结果与整段重解析的后缀完全一致。
    /// 之所以要回退两个块而不是一个:最后一行还没写完时可能不被识别(如 `-` 还不是列表项),
    /// 写完后(`- `)会被**前一个**块吸收(接续上一个列表、表格行等),所以前一个块也要重解析;
    /// 再往前的块,其边界由已经完整的行决定,不会再变。
    /// - Parameters:
    ///   - text: 新的完整文本
    ///   - previous: 上一次的解析结果;为 nil 或文本不是其扩展时退回整段解析
    /// - Returns: 解析结果(与 `parseState(text)` 等价)
    public static func parseState(_ text: String, continuing previous: MarkdownParseState?) -> MarkdownParseState {
        let text = normalizedNewlines(text)
        guard let previous, !previous.starts.isEmpty, text.utf8.count >= previous.text.utf8.count,
              text.utf8.starts(with: previous.text.utf8) else { return parseState(text) }
        let keep = max(previous.blocks.count - 2, 0)
        let cut = previous.starts[keep]
        let cutIndex = text.utf8.index(text.utf8.startIndex, offsetBy: cut)
        let (tailBlocks, tailStarts) = parseCore(String(text[cutIndex...]))
        return MarkdownParseState(
            text: text,
            blocks: Array(previous.blocks.prefix(keep)) + tailBlocks,
            starts: Array(previous.starts.prefix(keep)) + tailStarts.map { $0 + cut }
        )
    }

    /// 整段解析:返回块序列与每个块起始行的 UTF-8 偏移。
    private static func parseCore(_ text: String) -> (blocks: [MarkdownBlock], starts: [Int]) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 每行起点的 UTF-8 偏移(行内容 + 换行符)
        var lineOffsets: [Int] = []
        lineOffsets.reserveCapacity(lines.count)
        var running = 0
        for line in lines { lineOffsets.append(running); running += line.utf8.count + 1 }
        var blocks: [MarkdownBlock] = []
        var starts: [Int] = []
        var index = 0
        var paragraph: [String] = []
        var paragraphStart = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            starts.append(lineOffsets[paragraphStart])
            paragraph.removeAll()
        }

        /// 追加一个起始于第 `line` 行的块。
        func add(_ block: MarkdownBlock, at line: Int) {
            blocks.append(block)
            starts.append(lineOffsets[line])
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let blockStart = index

            // 代码围栏
            if let fence = fenceInfo(trimmed) {
                flushParagraph()
                var body: [String] = []
                var closed = false
                index += 1
                while index < lines.count {
                    let current = lines[index]
                    if current.trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                        closed = true
                        index += 1
                        break
                    }
                    body.append(current)
                    index += 1
                }
                add(.code(language: fence.language, code: body.joined(separator: "\n"), isClosed: closed), at: blockStart)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // HTML 注释块(CommonMark 第 2 类 HTML 块):从 `<!--` 起到含 `-->` 的行止,渲染时整体隐藏(与 GitHub/VS Code 一致);
            // 未闭合时直到文末都算注释,流式输出写完 `-->` 后下一次续解析会重新识别
            if trimmed.hasPrefix("<!--") {
                flushParagraph()
                while index < lines.count {
                    let closed = lines[index].contains("-->")
                    index += 1
                    if closed { break }
                }
                continue
            }

            // 标题
            if let heading = headingInfo(trimmed) {
                flushParagraph()
                add(.heading(level: heading.level, text: heading.text), at: blockStart)
                index += 1
                continue
            }

            // 分隔线
            if isRule(trimmed) {
                flushParagraph()
                add(.rule, at: blockStart)
                index += 1
                continue
            }

            // 表格:表头行 + 分隔行
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = splitRow(trimmed)
                let aligns = tableAligns(lines[index + 1])
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard rowLine.hasPrefix("|") else { break }
                    rows.append(splitRow(rowLine))
                    index += 1
                }
                // GFM:数据行的单元格比表头多时,多出的部分被忽略(少了由渲染端补空格)。
                // 否则单元格里一个没转义的竖线(哪怕在行内代码里)就会让整张表多出一列空白列,挤窄其余列
                if !header.isEmpty { rows = rows.map { $0.count > header.count ? Array($0.prefix(header.count)) : $0 } }
                add(.table(header: header, rows: rows, aligns: aligns), at: blockStart)
                continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var content = String(current.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoted.append(content)
                    index += 1
                }
                add(.quote(quoted.joined(separator: "\n")), at: blockStart)
                continue
            }

            // 列表
            if listItem(line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    let current = lines[index]
                    if let item = listItem(current) {
                        items.append(item)
                        index += 1
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty, current.hasPrefix("  "), !items.isEmpty,
                              fenceInfo(current.trimmingCharacters(in: .whitespaces)) == nil {
                        // 列表项的续行
                        items[items.count - 1].text += "\n" + current.trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else {
                        break
                    }
                }
                add(.list(items), at: blockStart)
                continue
            }

            if paragraph.isEmpty { paragraphStart = index }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return (blocks, starts)
    }

    // MARK: - 辅助

    private static func fenceInfo(_ trimmed: String) -> (marker: String, language: String?)? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let rest = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            let language = rest.split(separator: " ").first.map(String.init)
            return (marker, (language?.isEmpty ?? true) ? nil : language)
        }
        return nil
    }

    private static func headingInfo(_ trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        for char in trimmed {
            if char == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level), trimmed.count > level else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3, let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    /// 拆分表格行:`\|` 是单元格内的字面竖线(不分列),其余 `|` 为列分隔。
    private static func splitRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                // 只有 `\|` 被还原成竖线;其他转义保持原样交给行内解析
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmed.first?.isEmpty == true { trimmed.removeFirst() }
        if trimmed.last?.isEmpty == true { trimmed.removeLast() }
        return trimmed
    }

    /// 解析分隔行里每列的对齐方式。
    /// - Parameter separator: 分隔行(如 `| :--- | ---: | :---: |`)
    /// - Returns: 与列一一对应的对齐
    static func tableAligns(_ separator: String) -> [MarkdownTableAlign] {
        splitRow(separator.trimmingCharacters(in: .whitespaces)).map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            default: return .none
            }
        }
    }

    /// 解析列表项行(支持 `-`、`*`、`+`、`1.`、`1)` 与任务列表)。
    private static func listItem(_ line: String) -> MarkdownListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let body = line.dropFirst(indent)
        var marker: String?
        var rest = Substring("")
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            marker = "•"
            rest = body.dropFirst(2)
        } else {
            let digits = body.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 9 {
                let after = body.dropFirst(digits.count)
                if let sep = after.first, sep == "." || sep == ")", after.dropFirst().first == " " {
                    marker = "\(digits)."
                    rest = after.dropFirst(2)
                }
            }
        }
        guard let marker else { return nil }
        var text = String(rest)
        var checked: Bool?
        if text.hasPrefix("[ ] ") { checked = false; text.removeFirst(4) }
        else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { checked = true; text.removeFirst(4) }
        return MarkdownListItem(level: indent / 2, marker: marker, text: text, checked: checked)
    }
}
