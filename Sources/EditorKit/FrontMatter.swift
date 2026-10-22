// @author ixxxxoooo
// Markdown 前置元数据(YAML front matter)的轻量解析:只认「键: 值」、行内列表与 `- 项` 块列表,
// 供阅读页把它渲染成属性卡片;遇到嵌套/多行标量等复杂写法返回 nil,调用方退回源码显示。

import Foundation

/// 前置元数据的值。
public enum FrontMatterValue: Sendable, Equatable {
    case text(String)
    case bool(Bool)
    case list([String])
}

/// 前置元数据的一个字段。
public struct FrontMatterField: Sendable, Equatable {
    public var key: String
    public var value: FrontMatterValue
}

/// 前置元数据解析器。
public enum FrontMatterParser {
    /// 解析前置元数据块(含首尾 `---` 行)。
    /// - Parameter source: 块源码
    /// - Returns: 字段列表(保持书写顺序);格式不是简单键值、或没有任何字段时返回 nil
    public static func parse(_ source: String) -> [FrontMatterField]? {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        guard lines.count >= 2, isFence(lines[0]), isFence(lines[lines.count - 1]) else { return nil }
        var fields: [FrontMatterField] = []
        var pendingList: Int?
        for raw in lines[1..<(lines.count - 1)] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("- ") || line == "-" {
                // 块列表项只能跟在「键:」(值为空)之后
                guard let index = pendingList else { return nil }
                var items: [String] = []
                if case .list(let old) = fields[index].value { items = old }
                items.append(unquote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
                fields[index].value = .list(items)
                continue
            }
            // 缩进的非列表行是嵌套结构或续行,不支持
            guard !raw.hasPrefix(" "), !raw.hasPrefix("\t"), let field = splitField(line) else { return nil }
            pendingList = field.value == .text("") ? fields.count : nil
            fields.append(field)
        }
        return fields.isEmpty ? nil : fields
    }

    /// 是否是 `---` 分隔行(允许尾随空白)。
    private static func isFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "---"
    }

    /// 拆「键: 值」;键只允许字母数字与 `_ - .`。
    private static func splitField(_ line: String) -> FrontMatterField? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else { return nil }
        let rest = String(line[line.index(after: colon)...])
        // `key:value`(冒号后没有空格)不是合法键值
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        let value = rest.trimmingCharacters(in: .whitespaces)
        // 多行标量(`|` / `>`)不支持
        guard !(value.hasPrefix("|") || value.hasPrefix(">")) else { return nil }
        return FrontMatterField(key: key, value: parseValue(key: key, value))
    }

    /// 解析值:布尔、行内列表 `[a, b]`、Cursor 的逗号分隔 `globs`,其余按文本。
    private static func parseValue(key: String, _ value: String) -> FrontMatterValue {
        if value == "true" { return .bool(true) }
        if value == "false" { return .bool(false) }
        if value.hasPrefix("["), value.hasSuffix("]") {
            let inner = value.dropFirst().dropLast()
            return .list(inner.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty })
        }
        let text = unquote(value)
        if key == "globs", text.contains(",") {
            return .list(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        return .text(text)
    }

    /// 去掉成对的单/双引号。
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }
}
