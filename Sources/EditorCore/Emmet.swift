// @author ixxxxoooo
// Emmet 缩写展开(HTML/JSX 与 CSS 子集):标签、`#id`、`.class`、`[属性]`、`{文本}`、`>` `+` `^` `()` `*n` `$` 编号、
// 隐式标签、常用别名,以及 CSS 属性缩写(`m10`、`df`、`p10-20`、`c#f00` 等)。输出为 snippet 源文本(含 `$n` 占位)。

import Foundation

/// Emmet 展开器。
public enum Emmet {
    /// 展开的目标语法。
    public enum Syntax: Sendable { case html, jsx, css }

    // MARK: 抽取缩写

    /// 自光标前向左抽取缩写。
    /// - Parameters:
    ///   - linePrefix: 行首到光标之间的文本
    ///   - syntax: 目标语法
    /// - Returns: 缩写及其在 `linePrefix` 中的 UTF-16 起点;没有可展开内容返回 nil
    public static func abbreviation(in linePrefix: String, syntax: Syntax) -> (text: String, start: Int)? {
        let scalars = Array(linePrefix.unicodeScalars)
        var index = scalars.count
        var bracketDepth = 0
        func allowed(_ s: Unicode.Scalar) -> Bool {
            if s.isASCII, s.properties.isAlphabetic || (s.value >= 48 && s.value <= 57) { return true }
            return "_:-#.*>+^$()!@/%".unicodeScalars.contains(s)
        }
        while index > 0 {
            let s = scalars[index - 1]
            if s == "]" || s == "}" { bracketDepth += 1; index -= 1; continue }
            if s == "[" || s == "{" {
                if bracketDepth == 0 { break }
                bracketDepth -= 1; index -= 1; continue
            }
            if bracketDepth > 0 { index -= 1; continue }
            if allowed(s) { index -= 1; continue }
            break
        }
        guard bracketDepth == 0, index < scalars.count else { return nil }
        var text = String(String.UnicodeScalarView(scalars[index...]))
        // 去掉开头不可能属于缩写的符号(如行首残留的 `-`、`>`)。
        if syntax != .css {
            while let first = text.unicodeScalars.first, ">+^*)-:".unicodeScalars.contains(first) { text.removeFirst() }
        }
        guard !text.isEmpty else { return nil }
        let prefixUnits = String(String.UnicodeScalarView(scalars[..<index])).utf16.count
        let removed = String(String.UnicodeScalarView(scalars[index...])).utf16.count - text.utf16.count
        return (text, prefixUnits + removed)
    }

    /// 展开缩写。
    /// - Parameters:
    ///   - abbreviation: 缩写
    ///   - syntax: 目标语法
    ///   - indentUnit: 子元素缩进单位
    /// - Returns: snippet 源文本;不是合法缩写返回 nil
    public static func expand(_ abbreviation: String, syntax: Syntax, indentUnit: String = "    ") -> String? {
        switch syntax {
        case .css: return expandCSS(abbreviation)
        case .html, .jsx:
            if abbreviation == "!" || abbreviation == "html:5" { return htmlDocument(indentUnit: indentUnit) }
            var parser = HTMLParser(Array(abbreviation))
            guard let nodes = parser.parse(), !nodes.isEmpty else { return nil }
            // 单个裸词若不是已知标签/别名,也按标签展开(与 VS Code 一致),但数字开头等非法形式已被解析器拒绝。
            var renderer = HTMLRenderer(indentUnit: indentUnit, selfClosingSuffix: syntax == .jsx ? " />" : ">")
            var output = ""
            for (offset, node) in nodes.enumerated() {
                if offset > 0 { output += "\n" }
                output += renderer.render(node, parent: nil, level: 0, repeatIndex: 1, repeatCount: 1)
            }
            return output + "$0"
        }
    }

    // MARK: HTML 模型

    private final class ENode {
        var name: String?
        var id: String?
        var classes: [String] = []
        var attributes: [(String, String?)] = []
        var text: String?
        var children: [ENode] = []
        var repeatIndex: Int?
        var repeatCount: Int?

        init(name: String? = nil) { self.name = name }

        func clone() -> ENode {
            let copy = ENode(name: name)
            copy.id = id
            copy.classes = classes
            copy.attributes = attributes
            copy.text = text
            copy.repeatIndex = repeatIndex
            copy.repeatCount = repeatCount
            copy.children = children.map { $0.clone() }
            return copy
        }
    }

    private struct HTMLParser {
        let chars: [Character]
        var position = 0

        init(_ chars: [Character]) { self.chars = chars }

        func peek(_ offset: Int = 0) -> Character? { position + offset < chars.count ? chars[position + offset] : nil }

        /// 解析整个缩写;存在未消费字符(非法)时返回 nil。
        mutating func parse() -> [ENode]? {
            let (nodes, _) = parseSequence()
            guard position == chars.count else { return nil }
            return nodes
        }

        mutating func parseSequence() -> (nodes: [ENode], climb: Int) {
            var nodes: [ENode] = []
            while true {
                guard let unit = parseUnit() else { return (nodes, 0) }
                nodes += unit
                switch peek() {
                case "+":
                    position += 1
                case ">":
                    position += 1
                    let (kids, climb) = parseSequence()
                    for node in unit { node.children = kids.map { $0.clone() } }
                    if climb > 1 { return (nodes, climb - 1) }
                    if climb == 0 { return (nodes, 0) }
                case "^":
                    var count = 0
                    while peek() == "^" { count += 1; position += 1 }
                    return (nodes, count)
                default:
                    return (nodes, 0)
                }
            }
        }

        /// 一个单元:元素或括号分组,带可选 `*n`。
        mutating func parseUnit() -> [ENode]? {
            var items: [ENode]
            if peek() == "(" {
                position += 1
                let (nodes, _) = parseSequence()
                guard peek() == ")" else { return nil }
                position += 1
                items = nodes
            } else {
                guard let element = parseElement() else { return nil }
                items = [element]
            }
            if peek() == "*" {
                position += 1
                var digits = ""
                while let c = peek(), c.isNumber { digits.append(c); position += 1 }
                guard let count = Int(digits), count >= 1, count <= 200 else { return nil }
                var repeated: [ENode] = []
                for i in 1...count {
                    for item in items {
                        let copy = item.clone()
                        copy.repeatIndex = i
                        copy.repeatCount = count
                        repeated.append(copy)
                    }
                }
                items = repeated
            }
            return items
        }

        mutating func parseElement() -> ENode? {
            let node = ENode()
            var name = ""
            while let c = peek(), c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" || c == "$" {
                if name.isEmpty, c.isNumber || c == "-" { return nil }
                name.append(c)
                position += 1
            }
            if !name.isEmpty { node.name = name }
            var consumed = !name.isEmpty
            loop: while let c = peek() {
                switch c {
                case "#":
                    position += 1
                    node.id = readWord()
                    consumed = true
                case ".":
                    position += 1
                    let word = readWord()
                    guard !word.isEmpty else { return nil }
                    node.classes.append(word)
                    consumed = true
                case "[":
                    position += 1
                    guard readAttributes(into: node) else { return nil }
                    consumed = true
                case "{":
                    position += 1
                    var depth = 1
                    var text = ""
                    while let t = peek() {
                        position += 1
                        if t == "{" { depth += 1 }
                        if t == "}" { depth -= 1; if depth == 0 { break } }
                        text.append(t)
                    }
                    guard depth == 0 else { return nil }
                    node.text = text
                    consumed = true
                default:
                    break loop
                }
            }
            return consumed ? node : nil
        }

        mutating func readWord() -> String {
            var word = ""
            while let c = peek(), c.isLetter || c.isNumber || c == "-" || c == "_" || c == "$" || c == ":" {
                word.append(c)
                position += 1
            }
            return word
        }

        /// 读取 `[a=b c="d e" f]` 直到 `]`。
        mutating func readAttributes(into node: ENode) -> Bool {
            while let c = peek() {
                if c == "]" { position += 1; return true }
                if c == " " { position += 1; continue }
                var key = ""
                while let k = peek(), k != "=", k != " ", k != "]" { key.append(k); position += 1 }
                guard !key.isEmpty else { return false }
                if peek() == "=" {
                    position += 1
                    var value = ""
                    if let quote = peek(), quote == "\"" || quote == "'" {
                        position += 1
                        while let v = peek(), v != quote { value.append(v); position += 1 }
                        guard peek() == quote else { return false }
                        position += 1
                    } else {
                        while let v = peek(), v != " ", v != "]" { value.append(v); position += 1 }
                    }
                    node.attributes.append((key, value))
                } else {
                    node.attributes.append((key, nil))
                }
            }
            return false
        }
    }

    private static let selfClosingTags: Set<String> = ["br", "hr", "img", "input", "link", "meta", "area", "base", "col", "embed", "source", "track", "wbr"]
    private static let inlineTags: Set<String> = ["a", "span", "em", "strong", "b", "i", "u", "code", "label", "small", "abbr", "cite", "kbd", "mark", "q", "s", "sub", "sup", "time", "button"]

    /// 标签别名:缩写 → (真实标签, 默认属性)。
    private static let aliases: [String: (String, [(String, String?)])] = [
        "a": ("a", [("href", "")]),
        "img": ("img", [("src", ""), ("alt", "")]),
        "link": ("link", [("rel", "stylesheet"), ("href", "")]),
        "script:src": ("script", [("src", "")]),
        "input": ("input", [("type", "text")]),
        "btn": ("button", []),
        "bq": ("blockquote", []),
        "fig": ("figure", []),
        "figc": ("figcaption", []),
        "ifr": ("iframe", [("src", ""), ("frameborder", "0")]),
        "adr": ("address", []),
        "art": ("article", []),
        "str": ("strong", []),
        "sect": ("section", []),
        "tarea": ("textarea", [("cols", "30"), ("rows", "10")]),
        "inp": ("input", [("type", "text")]),
        "btn:s": ("button", [("type", "submit")]),
        "form:post": ("form", [("action", ""), ("method", "post")]),
        "input:c": ("input", [("type", "checkbox")]),
        "input:p": ("input", [("type", "password")]),
        "input:b": ("input", [("type", "button")]),
        "input:s": ("input", [("type", "submit")]),
    ]

    private struct HTMLRenderer {
        let indentUnit: String
        let selfClosingSuffix: String
        var stopCounter = 1

        init(indentUnit: String, selfClosingSuffix: String) {
            self.indentUnit = indentUnit
            self.selfClosingSuffix = selfClosingSuffix
        }

        mutating func nextStop() -> String { defer { stopCounter += 1 }; return "$\(stopCounter)" }

        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "}", with: "\\}")
        }

        /// `$` 编号替换:连续 `$` 表示补零位数;`\$` 不替换。
        func number(_ text: String, index: Int) -> String {
            var result = ""
            let chars = Array(text)
            var i = 0
            while i < chars.count {
                if chars[i] == "$" {
                    var run = 0
                    while i < chars.count, chars[i] == "$" { run += 1; i += 1 }
                    let digits = String(index)
                    result += String(repeating: "0", count: max(run - digits.count, 0)) + digits
                } else {
                    result.append(chars[i]); i += 1
                }
            }
            return result
        }

        mutating func render(_ node: ENode, parent: String?, level: Int, repeatIndex: Int, repeatCount: Int) -> String {
            let index = node.repeatIndex ?? repeatIndex
            let count = node.repeatCount ?? repeatCount
            _ = count
            var rawName = node.name.map { number($0, index: index) }
            var defaults: [(String, String?)] = []
            if let name = rawName, let alias = Emmet.aliases[name] { rawName = alias.0; defaults = alias.1 }
            let name = rawName ?? Emmet.implicitName(forParent: parent, hasClass: !node.classes.isEmpty || node.id != nil)
            var attrs = ""
            if let id = node.id { attrs += " id=\"\(escape(number(id, index: index)))\"" }
            if !node.classes.isEmpty { attrs += " class=\"\(escape(node.classes.map { number($0, index: index) }.joined(separator: " ")))\"" }
            // 默认属性被显式属性覆盖。
            var merged: [(String, String?)] = defaults
            for (key, value) in node.attributes {
                if let existing = merged.firstIndex(where: { $0.0 == key }) { merged[existing] = (key, value) } else { merged.append((key, value)) }
            }
            for (key, value) in merged {
                let rendered: String
                if let value, !value.isEmpty { rendered = escape(number(value, index: index)) } else { rendered = nextStop() }
                attrs += " \(key)=\"\(rendered)\""
            }
            if Emmet.selfClosingTags.contains(name) { return "<\(name)\(attrs)\(selfClosingSuffix)" }
            let open = "<\(name)\(attrs)>"
            let close = "</\(name)>"
            if node.children.isEmpty {
                if let text = node.text { return open + escape(number(text, index: index)) + close }
                return open + nextStop() + close
            }
            let inner = indentUnit
            var lines: [String] = []
            for child in node.children {
                let rendered = render(child, parent: name, level: level + 1, repeatIndex: index, repeatCount: count)
                lines.append(rendered.split(separator: "\n", omittingEmptySubsequences: false).map { inner + $0 }.joined(separator: "\n"))
            }
            let prefix = node.text.map { escape(number($0, index: index)) }
            return open + (prefix.map { "\n" + inner + $0 } ?? "") + "\n" + lines.joined(separator: "\n") + "\n" + close
        }
    }

    /// 缺省标签名按父元素推断。
    private static func implicitName(forParent parent: String?, hasClass: Bool) -> String {
        switch parent {
        case "ul", "ol": return "li"
        case "table", "tbody", "thead", "tfoot": return "tr"
        case "tr": return "td"
        case "select", "optgroup": return "option"
        case "dl": return "dt"
        default:
            if let parent, inlineTags.contains(parent) { return "span" }
            return "div"
        }
    }

    private static func htmlDocument(indentUnit: String) -> String {
        let i = indentUnit
        return "<!DOCTYPE html>\n<html lang=\"en\">\n\(i)<head>\n\(i)\(i)<meta charset=\"UTF-8\">\n"
            + "\(i)\(i)<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n"
            + "\(i)\(i)<title>${1:Document}</title>\n\(i)</head>\n\(i)<body>\n\(i)\(i)$0\n\(i)</body>\n</html>"
    }

    // MARK: CSS

    private static let cssProperties: [String: String] = [
        "m": "margin", "mt": "margin-top", "mr": "margin-right", "mb": "margin-bottom", "ml": "margin-left",
        "p": "padding", "pt": "padding-top", "pr": "padding-right", "pb": "padding-bottom", "pl": "padding-left",
        "w": "width", "h": "height", "maw": "max-width", "mah": "max-height", "miw": "min-width", "mih": "min-height",
        "t": "top", "r": "right", "b": "bottom", "l": "left", "z": "z-index", "fz": "font-size", "fw": "font-weight",
        "lh": "line-height", "c": "color", "bg": "background", "bgc": "background-color", "op": "opacity",
        "bd": "border", "bdrs": "border-radius", "bdt": "border-top", "bdb": "border-bottom", "ls": "letter-spacing",
        "gap": "gap", "fx": "flex", "fxg": "flex-grow", "fxs": "flex-shrink", "ov": "overflow", "cur": "cursor",
        "trs": "transition", "d": "display", "pos": "position", "ta": "text-align", "td": "text-decoration",
        "va": "vertical-align", "fl": "float", "ff": "font-family", "bxsh": "box-shadow", "bxz": "box-sizing",
    ]

    /// 整词缩写(属性+值)。
    private static let cssShorthands: [String: String] = [
        "df": "display: flex", "dg": "display: grid", "db": "display: block", "dib": "display: inline-block",
        "dn": "display: none", "di": "display: inline", "posa": "position: absolute", "posr": "position: relative",
        "posf": "position: fixed", "poss": "position: sticky", "jcc": "justify-content: center",
        "jcsb": "justify-content: space-between", "jcfs": "justify-content: flex-start", "jcfe": "justify-content: flex-end",
        "aic": "align-items: center", "aifs": "align-items: flex-start", "aife": "align-items: flex-end",
        "fxdc": "flex-direction: column", "fxdr": "flex-direction: row", "fxw": "flex-wrap: wrap",
        "tac": "text-align: center", "tal": "text-align: left", "tar": "text-align: right",
        "fwb": "font-weight: bold", "fwn": "font-weight: normal", "cp": "cursor: pointer",
        "ovh": "overflow: hidden", "ova": "overflow: auto", "tdn": "text-decoration: none", "bxzbb": "box-sizing: border-box",
    ]

    private static let unitlessProperties: Set<String> = ["z-index", "opacity", "line-height", "font-weight", "flex", "flex-grow", "flex-shrink"]

    private static func expandCSS(_ abbreviation: String) -> String? {
        if let direct = cssShorthands[abbreviation] { return direct + ";$0" }
        // 拆出属性前缀与值。
        let chars = Array(abbreviation)
        var split = 0
        while split < chars.count, chars[split].isLetter { split += 1 }
        let key = String(chars[0..<split])
        guard let property = cssProperties[key] else { return nil }
        let rest = String(chars[split...])
        guard !rest.isEmpty else { return property + ": $1;$0" }
        // 十六进制颜色。
        if rest.hasPrefix("#") { return "\(property): \(rest);$0" }
        var values: [String] = []
        // 以 `-` 分隔多个值;值开头的 `-` 表示负数(出现在开头或两个 `-` 相连)。
        var current = ""
        var previousWasSeparator = true
        for ch in rest {
            if ch == "-" {
                if previousWasSeparator { current.append(ch); previousWasSeparator = false; continue }
                values.append(current)
                current = ""
                previousWasSeparator = true
            } else {
                current.append(ch)
                previousWasSeparator = false
            }
        }
        if !current.isEmpty { values.append(current) }
        var rendered: [String] = []
        for value in values {
            guard let converted = cssValue(value, property: property) else { return nil }
            rendered.append(converted)
        }
        return "\(property): \(rendered.joined(separator: " "));$0"
    }

    /// 单个值:数字补单位,`p`→`%`,`e`→`em`,`x`→`ex`;其余按关键字原样。
    private static func cssValue(_ value: String, property: String) -> String? {
        let pattern = #"^(-?\d+(?:\.\d+)?)([a-z%]*)$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            return value.allSatisfy { $0.isLetter || $0 == "-" } ? value : nil
        }
        var digits = ""
        var suffix = ""
        for ch in value { if ch.isNumber || ch == "." || (ch == "-" && digits.isEmpty) { digits.append(ch) } else { suffix.append(ch) } }
        switch suffix {
        case "": return unitlessProperties.contains(property) || digits == "0" ? digits : digits + "px"
        case "p": return digits + "%"
        case "e": return digits + "em"
        case "x": return digits + "ex"
        case "r": return digits + "rem"
        default: return digits + suffix
        }
    }
}
