// @author ixxxxoooo
// Markdown + YAML frontmatter 文档:按"顶层键"分块,只改动已知字段,未知字段与注释原样保留。

import Foundation

/// 带 frontmatter 的 Markdown 文档。
public struct MarkdownDocument: Sendable, Equatable {
    /// frontmatter 的一个顶层键及其续行(缩进行、列表项)
    struct Block: Sendable, Equatable {
        var key: String?          // nil 表示注释/空行
        var lines: [String]
    }

    var blocks: [Block]
    public var hasFrontmatter: Bool
    public var body: String

    public init(body: String = "") {
        blocks = []
        hasFrontmatter = false
        self.body = body
    }

    // MARK: - 解析与渲染

    /// 解析文本。
    public init(parsing text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        blocks = []
        hasFrontmatter = false
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            body = normalized
            return
        }
        hasFrontmatter = true
        let header = Array(lines[1..<end])
        lines = Array(lines[(end + 1)...])
        body = lines.joined(separator: "\n")
        for line in header {
            if let key = Self.topLevelKey(of: line) {
                blocks.append(Block(key: key, lines: [line]))
            } else if var last = blocks.last, last.key != nil, line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("- ") {
                last.lines.append(line)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(Block(key: nil, lines: [line]))
            }
        }
    }

    /// 渲染为文本。
    public func render() -> String {
        guard hasFrontmatter, !blocks.isEmpty else { return body }
        let header = blocks.flatMap(\.lines).joined(separator: "\n")
        return "---\n\(header)\n---\n\(body)"
    }

    static func topLevelKey(of line: String) -> String? {
        guard let first = line.first, first.isLetter || first.isNumber || first == "_" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        guard key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return key
    }

    // MARK: - 读取

    /// 所有顶层键(按出现顺序)。
    public var keys: [String] { blocks.compactMap(\.key) }

    /// 读取标量值(去掉引号;块标量 `|` / `>` 合并各行)。
    public func value(_ key: String) -> String? {
        guard let block = blocks.first(where: { $0.key == key }), let first = block.lines.first,
              let colon = first.firstIndex(of: ":") else { return nil }
        var raw = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if raw == "|" || raw == ">" || raw.hasPrefix("|-") || raw.hasPrefix(">-") {
            let folded = raw.hasPrefix(">")
            let rest = block.lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            return rest.joined(separator: folded ? " " : "\n")
        }
        if let hash = raw.range(of: " #"), !raw.hasPrefix("\""), !raw.hasPrefix("'") { raw = String(raw[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if raw.count >= 2, (raw.hasPrefix("\"") && raw.hasSuffix("\"")) {
            raw = String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
        } else if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            raw = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    /// 读取布尔值。
    public func bool(_ key: String) -> Bool? {
        switch value(key)?.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: return nil
        }
    }

    /// 读取列表:支持 `[a, b]`、`a, b` 与逐行 `- a`。
    public func list(_ key: String) -> [String]? {
        guard let block = blocks.first(where: { $0.key == key }), let first = block.lines.first,
              let colon = first.firstIndex(of: ":") else { return nil }
        let inline = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if inline.isEmpty {
            let items = block.lines.dropFirst().compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("- ") ? Self.unquote(String(trimmed.dropFirst(2))) : nil
            }
            return items
        }
        var text = inline
        if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        return text.split(separator: ",").map { Self.unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    private static func unquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    // MARK: - 属性视图(Obsidian 风格 Properties)

    /// frontmatter 的一个属性(顶层键)。
    public struct Property: Sendable, Equatable, Identifiable {
        /// 属性值类型,决定属性面板里用哪种控件。
        public enum Kind: Sendable, Equatable { case text, bool, list }
        public var id: String { key }
        public let key: String
        public let kind: Kind
        /// 文本值(`bool` 时为 "true"/"false";`list` 时为空)
        public let text: String
        /// 列表项(仅 `list`)
        public let items: [String]
    }

    /// 全部属性(按出现顺序);注释与空行不算属性。
    public var properties: [Property] {
        keys.map { key in
            guard let block = blocks.first(where: { $0.key == key }), let first = block.lines.first,
                  let colon = first.firstIndex(of: ":") else {
                return Property(key: key, kind: .text, text: "", items: [])
            }
            let inline = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let hasDashItems = block.lines.dropFirst().contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            if (inline.hasPrefix("[") && inline.hasSuffix("]")) || (inline.isEmpty && hasDashItems) {
                return Property(key: key, kind: .list, text: "", items: list(key) ?? [])
            }
            if let flag = bool(key) { return Property(key: key, kind: .bool, text: flag ? "true" : "false", items: []) }
            return Property(key: key, kind: .text, text: value(key) ?? "", items: [])
        }
    }

    /// 键名是否合法(字母、数字、下划线、连字符)。
    public static func isValidKey(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// 新增一个空属性。
    /// - Parameter key: 键名;非法或已存在时不修改
    /// - Returns: 是否新增成功
    @discardableResult
    public mutating func addProperty(key: String) -> Bool {
        guard Self.isValidKey(key), !keys.contains(key) else { return false }
        replaceOrAppend(key, ["\(key):"])
        return true
    }

    /// 重命名属性,保留值与续行。
    /// - Returns: 是否重命名成功(旧键不存在、新键非法或已存在时失败)
    @discardableResult
    public mutating func renameKey(_ old: String, to new: String) -> Bool {
        guard old != new, Self.isValidKey(new), !keys.contains(new),
              let index = blocks.firstIndex(where: { $0.key == old }),
              let first = blocks[index].lines.first, let colon = first.firstIndex(of: ":") else { return false }
        blocks[index].lines[0] = new + String(first[colon...])
        blocks[index].key = new
        return true
    }

    // MARK: - 修改

    /// 设置标量值;`nil` 删除该键(含续行)。已有键原位替换,新键追加到末尾。
    public mutating func setValue(_ key: String, _ value: String?) {
        guard let value else { removeKey(key); return }
        let lines = Self.render(key: key, value: value)
        replaceOrAppend(key, lines)
    }

    /// 设置布尔值;`nil` 删除。
    public mutating func setBool(_ key: String, _ value: Bool?) {
        guard let value else { removeKey(key); return }
        replaceOrAppend(key, ["\(key): \(value ? "true" : "false")"])
    }

    /// 设置列表(写成行内 `[a, b]`);`nil` 或空数组删除。
    public mutating func setList(_ key: String, _ values: [String]?) {
        guard let values, !values.isEmpty else { removeKey(key); return }
        replaceOrAppend(key, ["\(key): [\(values.map(Self.quoteIfNeeded).joined(separator: ", "))]"])
    }

    /// 删除某个键。
    public mutating func removeKey(_ key: String) {
        blocks.removeAll { $0.key == key }
    }

    private mutating func replaceOrAppend(_ key: String, _ lines: [String]) {
        hasFrontmatter = true
        if let index = blocks.firstIndex(where: { $0.key == key }) {
            blocks[index].lines = lines
        } else {
            blocks.append(Block(key: key, lines: lines))
        }
    }

    static func render(key: String, value: String) -> [String] {
        if value.contains("\n") {
            return ["\(key): |"] + value.components(separatedBy: "\n").map { "  \($0)" }
        }
        return ["\(key): \(quoteIfNeeded(value))"]
    }

    static func quoteIfNeeded(_ value: String) -> String {
        let special = "!&*[]{}|>'\"%@`#,"
        let needs = value.isEmpty || value != value.trimmingCharacters(in: .whitespaces)
            || value.contains(": ") || value.contains(" #") || value.hasSuffix(":")
            || (value.first.map { special.contains($0) } ?? false)
            || ["true", "false", "null", "yes", "no"].contains(value.lowercased())
        guard needs else { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
