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

/// Markdown 块。
public enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String, isClosed: Bool)
    case list([MarkdownListItem])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

/// 块级解析入口。
public enum MarkdownParser {
    /// 解析 Markdown 文本。
    /// - Parameter text: 原始文本
    /// - Returns: 块序列
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

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
                blocks.append(.code(language: fence.language, code: body.joined(separator: "\n"), isClosed: closed))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // 标题
            if let heading = headingInfo(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            // 分隔线
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // 表格:表头行 + 分隔行
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = splitRow(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard rowLine.hasPrefix("|") else { break }
                    rows.append(splitRow(rowLine))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
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
                blocks.append(.quote(quoted.joined(separator: "\n")))
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
                blocks.append(.list(items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
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

    private static func splitRow(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
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
