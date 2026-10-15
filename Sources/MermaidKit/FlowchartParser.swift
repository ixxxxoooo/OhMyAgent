// @author ygw
// flowchart / graph 语法解析。

import Foundation

/// 字符游标。
struct Cursor {
    let chars: [Character]
    var i = 0
    init(_ s: String) { chars = Array(s) }
    var atEnd: Bool { i >= chars.count }
    var peek: Character? { i < chars.count ? chars[i] : nil }
    func peek(_ offset: Int) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }
    mutating func skipSpaces() { while let c = peek, c == " " || c == "\t" { i += 1 } }
    /// 当前位置是否以 `prefix` 开头。
    func hasPrefix(_ prefix: String) -> Bool {
        let p = Array(prefix)
        guard i + p.count <= chars.count else { return false }
        return Array(chars[i..<(i + p.count)]) == p
    }
    /// 剩余字符串。
    var rest: String { String(chars[min(i, chars.count)...]) }
}

enum FlowchartParser {
    /// 解析 flowchart/graph 源码。
    static func parse(_ lines: [String]) throws -> FlowModel {
        var model = FlowModel()
        var stack: [String] = []
        for (lineIndex, raw) in lines.enumerated() {
            let number = lineIndex + 1
            for statement in splitStatements(raw) {
                let line = statement.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("%%") { continue }
                let lower = line.lowercased()
                if lineIndex == 0 || lower.hasPrefix("flowchart ") || lower.hasPrefix("graph ") || lower == "flowchart" || lower == "graph" {
                    if lower.hasPrefix("flowchart") || lower.hasPrefix("graph") {
                        let parts = line.split(separator: " ").map(String.init)
                        if parts.count > 1, let d = MDirection(token: parts[1]) { model.direction = d }
                        continue
                    }
                }
                if lower == "end" { _ = stack.popLast(); continue }
                if lower.hasPrefix("subgraph") {
                    let (id, title) = parseSubgraphHeader(String(line.dropFirst("subgraph".count)))
                    model.addSub(id: id, title: title, parent: stack.last)
                    stack.append(id)
                    continue
                }
                if ["style ", "classdef ", "class ", "linkstyle ", "click ", "direction ", "acctitle", "accdescr", "title "].contains(where: { lower.hasPrefix($0) }) { continue }
                do { try parseStatement(line, into: &model, parent: stack.last) }
                catch let e as MermaidError { throw MermaidError(line: number, e.message) }
            }
        }
        return model
    }

    /// 按 `;` 拆分(忽略引号与括号内)。
    static func splitStatements(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var quote = false
        for c in line {
            if c == "\"" { quote.toggle() }
            if !quote {
                if "([{".contains(c) { depth += 1 }
                if ")]}".contains(c) { depth = max(0, depth - 1) }
                if c == ";" && depth == 0 { result.append(current); current = ""; continue }
            }
            current.append(c)
        }
        result.append(current)
        return result
    }

    /// 解析 `subgraph` 头:`ID [标题]` / `标题` / `"标题"`。
    static func parseSubgraphHeader(_ text: String) -> (String, String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let open = t.firstIndex(of: "["), t.hasSuffix("]") {
            let id = String(t[..<open]).trimmingCharacters(in: .whitespaces)
            let title = unquote(String(t[t.index(after: open)..<t.index(before: t.endIndex)]))
            return (id.isEmpty ? title : id, title)
        }
        let title = unquote(t)
        return (title.replacingOccurrences(of: " ", with: "_"), title)
    }

    /// 去掉首尾引号与 markdown 反引号。
    static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { t = String(t.dropFirst().dropLast()) }
        if t.count >= 2, t.hasPrefix("`"), t.hasSuffix("`") { t = String(t.dropFirst().dropLast()) }
        return t
    }

    // MARK: 语句

    private static func parseStatement(_ line: String, into model: inout FlowModel, parent: String?) throws {
        var cur = Cursor(line)
        var previous: [String]?
        var pending: FlowEdge?
        while true {
            cur.skipSpaces()
            if cur.atEnd { break }
            let group = try parseNodeGroup(&cur, model: &model, parent: parent)
            if let previous, let pending {
                for u in previous { for v in group {
                    var e = pending; e.from = u; e.to = v
                    model.edges.append(e)
                } }
            }
            previous = group
            cur.skipSpaces()
            if cur.atEnd { break }
            guard let op = parseEdgeOp(&cur) else { throw MermaidError("无法识别的连线:\(cur.rest.prefix(12))") }
            pending = op
        }
        if pending != nil, previous != nil, let p = pending, p.from.isEmpty {
            // 行尾悬空连线,忽略
        }
    }

    private static func parseNodeGroup(_ cur: inout Cursor, model: inout FlowModel, parent: String?) throws -> [String] {
        var ids: [String] = []
        while true {
            cur.skipSpaces()
            let id = parseID(&cur)
            guard !id.isEmpty else { throw MermaidError("缺少节点标识:\(cur.rest.prefix(12))") }
            if let (text, shape) = try parseShape(&cur) {
                model.declare(id, text: text, shape: shape, parent: parent)
            } else {
                model.ensureNode(id, parent: parent)
            }
            if cur.hasPrefix(":::") {
                cur.i += 3
                _ = parseID(&cur)
            }
            ids.append(id)
            cur.skipSpaces()
            if cur.peek == "&" { cur.i += 1; continue }
            break
        }
        return ids
    }

    private static func isIDChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || (c.unicodeScalars.first.map { $0.value > 127 } ?? false)
    }

    private static func parseID(_ cur: inout Cursor) -> String {
        var s = ""
        while let c = cur.peek {
            if isIDChar(c) { s.append(c); cur.i += 1 }
            else if c == "-", let n = cur.peek(1), isIDChar(n) { s.append(c); cur.i += 1 }
            else { break }
        }
        return s
    }

    /// 形状开闭定界符,按最长优先。
    private static let shapeTable: [(open: String, close: String, shape: MShape)] = [
        ("(((", ")))", .doubleCircle), ("((", "))", .circle), ("([", "])", .stadium), ("(", ")", .rounded),
        ("[[", "]]", .subroutine), ("[(", ")]", .cylinder), ("[/", "\\]", .trapezoid), ("[\\", "/]", .trapezoid),
        ("[/", "/]", .parallelogram), ("[\\", "\\]", .parallelogram), ("[", "]", .rect),
        ("{{", "}}", .hexagon), ("{", "}", .diamond), (">", "]", .asymmetric),
    ]

    private static func parseShape(_ cur: inout Cursor) throws -> (String, MShape)? {
        guard let c = cur.peek, "([{>".contains(c) else { return nil }
        // 针对同一开符号的多种闭符号,逐个尝试,选能找到闭合的第一个(平行四边形/梯形按闭符号区分)
        for entry in shapeTable where cur.hasPrefix(entry.open) {
            let start = cur.i + entry.open.count
            if let end = findClose(cur.chars, from: start, close: Array(entry.close)) {
                let raw = String(cur.chars[start..<end])
                cur.i = end + entry.close.count
                return (unquote(raw), entry.shape)
            }
        }
        throw MermaidError("节点形状未闭合:\(cur.rest.prefix(12))")
    }

    private static func findClose(_ chars: [Character], from: Int, close: [Character]) -> Int? {
        var i = from
        var inQuote = false
        while i < chars.count {
            if chars[i] == "\"" { inQuote.toggle() }
            if !inQuote, i + close.count <= chars.count, Array(chars[i..<(i + close.count)]) == close { return i }
            i += 1
        }
        return nil
    }

    // MARK: 连线

    private static func parseEdgeOp(_ cur: inout Cursor) -> FlowEdge? {
        let rest = cur.rest
        let patterns: [(String, (NSTextCheckingResult, String) -> FlowEdge)] = [
            (#"^(<)?--\s+(.+?)\s+--(>|-|o|x)?"#, { m, s in inlineEdge(m, s, style: .solid) }),
            (#"^(<)?==\s+(.+?)\s+==(>|=|o|x)?"#, { m, s in inlineEdge(m, s, style: .thick) }),
            (#"^(<)?-\.\s+(.+?)\s+\.-(>)?"#, { m, s in inlineEdge(m, s, style: .dashed) }),
            (#"^(<)?(-{2,}|={2,}|-\.+-)(>|o(?=\s|$)|x(?=\s|$))?"#, { m, s in plainEdge(m, s) }),
        ]
        for (pattern, build) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) else { continue }
            var edge = build(m, rest)
            let consumed = (rest as NSString).substring(to: m.range.length)
            cur.i += consumed.count
            // 可选的 |标签|
            var probe = cur
            probe.skipSpaces()
            if probe.peek == "|" {
                probe.i += 1
                var label = ""
                while let c = probe.peek, c != "|" { label.append(c); probe.i += 1 }
                if probe.peek == "|" { probe.i += 1; cur = probe; edge.label = unquote(label) }
            }
            return edge
        }
        return nil
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        let r = m.range(at: i)
        guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
        return String(s[range])
    }

    private static func head(_ token: String?) -> MArrow {
        switch token { case ">": .arrow; case "o": .circle; case "x": .cross; default: .none }
    }

    private static func inlineEdge(_ m: NSTextCheckingResult, _ s: String, style: MLineStyle) -> FlowEdge {
        var e = FlowEdge(from: "", to: "", label: group(m, 2, s).map(unquote), style: style, start: .none, end: .none)
        if group(m, 1, s) != nil { e.start = .arrow }
        e.end = head(group(m, 3, s))
        return e
    }

    private static func plainEdge(_ m: NSTextCheckingResult, _ s: String) -> FlowEdge {
        let body = group(m, 2, s) ?? "--"
        let style: MLineStyle = body.hasPrefix("=") ? .thick : (body.contains(".") ? .dashed : .solid)
        var e = FlowEdge(from: "", to: "", label: nil, style: style, start: .none, end: .none)
        if group(m, 1, s) != nil { e.start = .arrow }
        e.end = head(group(m, 3, s))
        return e
    }
}
