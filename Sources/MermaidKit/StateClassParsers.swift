// @author ixxxxoooo
// stateDiagram(-v2) 与 classDiagram 解析,均产出 FlowModel。

import Foundation

enum StateParser {
    /// 解析状态图。
    static func parse(_ lines: [String]) throws -> FlowModel {
        var model = FlowModel()
        var stack: [String] = []
        var titles: [String: String] = [:]
        var inNote = false
        let transition = try NSRegularExpression(pattern: #"^(\[\*\]|[^\s:\[\]{}]+)\s*-->\s*(\[\*\]|[^\s:\[\]{}]+)\s*(?::\s*(.*))?$"#)
        let describe = try NSRegularExpression(pattern: #"^([^\s:\[\]{}-]+)\s*:\s*(.+)$"#)
        let alias = try NSRegularExpression(pattern: #"^state\s+"([^"]+)"\s+as\s+(\S+)\s*$"#)
        let stereo = try NSRegularExpression(pattern: #"^state\s+(\S+)\s+<<(\w+)>>\s*$"#)
        let composite = try NSRegularExpression(pattern: #"^state\s+(?:"([^"]+)"\s+as\s+)?(\S+?)\s*\{\s*$"#)

        func ref(_ token: String, isSource: Bool) -> String {
            guard token == "[*]" else { return token }
            let scope = stack.last ?? "root"
            let id = (isSource ? "__start_" : "__end_") + scope
            if model.nodes[id] == nil {
                model.declare(id, text: "", shape: isSource ? .startDot : .endDot, parent: stack.last)
            }
            return id
        }
        func ensure(_ id: String) {
            if model.nodes[id] == nil && model.subs[id] == nil {
                model.ensureNode(id, parent: stack.last)
                model.nodes[id]?.text = titles[id] ?? id
                model.nodes[id]?.shape = .rounded
            }
        }

        for (idx, raw) in lines.enumerated() where idx > 0 {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue }
            let lower = line.lowercased()
            if inNote { if lower.hasPrefix("end note") { inNote = false }; continue }
            if lower.hasPrefix("note ") { if !line.contains(":") { inNote = true }; continue }
            if lower.hasPrefix("direction ") {
                if let d = MDirection(token: String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)), stack.isEmpty { model.direction = d }
                continue
            }
            if line == "}" { _ = stack.popLast(); continue }
            if line == "--" { continue }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            func capture(_ m: NSTextCheckingResult, _ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            if let m = composite.firstMatch(in: line, range: full), let id = capture(m, 2) {
                let title = capture(m, 1) ?? titles[id] ?? id
                model.addSub(id: id, title: title, parent: stack.last)
                stack.append(id)
                continue
            }
            if let m = alias.firstMatch(in: line, range: full), let text = capture(m, 1), let id = capture(m, 2) {
                titles[id] = text
                model.declare(id, text: text, shape: .rounded, parent: stack.last)
                continue
            }
            if let m = stereo.firstMatch(in: line, range: full), let id = capture(m, 1), let kind = capture(m, 2) {
                switch kind.lowercased() {
                case "choice": model.declare(id, text: "", shape: .diamond, parent: stack.last)
                case "fork", "join": model.declare(id, text: "", shape: .rect, parent: stack.last)
                default: model.declare(id, text: id, shape: .rounded, parent: stack.last)
                }
                continue
            }
            if lower.hasPrefix("state ") {
                let id = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { ensure(id) }
                continue
            }
            if let m = transition.firstMatch(in: line, range: full), let a = capture(m, 1), let b = capture(m, 2) {
                let u = ref(a, isSource: true), v = ref(b, isSource: false)
                if a != "[*]" { ensure(u) }
                if b != "[*]" { ensure(v) }
                model.edges.append(FlowEdge(from: u, to: v, label: capture(m, 3).flatMap { $0.isEmpty ? nil : $0 }))
                continue
            }
            if let m = describe.firstMatch(in: line, range: full), let id = capture(m, 1), let text = capture(m, 2) {
                if model.nodes[id] == nil { model.declare(id, text: text, shape: .rounded, parent: stack.last) }
                else { model.nodes[id]?.text = text; model.nodes[id]?.declared = true }
                continue
            }
            throw MermaidError(line: idx + 1, String(localized: "无法识别的状态图语句:\(line.prefix(24))"))
        }
        return model
    }
}

enum ClassParser {
    /// 解析类图。
    static func parse(_ lines: [String]) throws -> FlowModel {
        var model = FlowModel()
        model.direction = .topDown
        var current: String?
        let relation = try NSRegularExpression(pattern: #"^(\S+?)\s*(?:"[^"]*"\s*)?(<\|--|\*--|o--|-->|<--|\.\.>|<\.\.|\.\.\|>|<\|\.\.|--\*|--o|--\|>|--|\.\.)\s*(?:"[^"]*"\s*)?(\S+?)\s*(?::\s*(.*))?$"#)
        let member = try NSRegularExpression(pattern: #"^(\S+?)\s*:\s*(.+)$"#)

        func name(_ raw: String) -> String {
            raw.replacingOccurrences(of: "~", with: "<", range: raw.range(of: "~")).replacingOccurrences(of: "~", with: ">")
        }
        func ensure(_ raw: String) -> String {
            let id = raw.split(separator: "~").first.map(String.init) ?? raw
            if model.nodes[id] == nil {
                model.declare(id, text: name(raw), shape: .classBox, parent: nil)
            }
            return id
        }
        func add(_ id: String, member text: String) {
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            if t.hasPrefix("<<") && t.hasSuffix(">>") {
                let kind = t.dropFirst(2).dropLast(2)
                if let n = model.nodes[id], !n.text.hasPrefix("«") { model.nodes[id]?.text = "«\(kind)»\n" + n.text }
            } else if t.contains("(") { model.nodes[id]?.methods.append(t) }
            else { model.nodes[id]?.fields.append(t) }
        }

        for (idx, raw) in lines.enumerated() where idx > 0 {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue }
            let lower = line.lowercased()
            if let cls = current {
                if line == "}" { current = nil } else { add(cls, member: line) }
                continue
            }
            if lower.hasPrefix("direction ") {
                if let d = MDirection(token: String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)) { model.direction = d }
                continue
            }
            if lower.hasPrefix("class ") {
                var rest = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                let opens = rest.hasSuffix("{")
                if opens { rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces) }
                let id = ensure(rest)
                if opens { current = id }
                continue
            }
            if lower.hasPrefix("note") || lower.hasPrefix("click ") || lower.hasPrefix("style ") || lower.hasPrefix("cssclass ") { continue }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = relation.firstMatch(in: line, range: full) {
                func cap(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
                if let a = cap(1), let op = cap(2), let b = cap(3) {
                    let u = ensure(a), v = ensure(b)
                    var e = FlowEdge(from: u, to: v, label: cap(4).flatMap { $0.isEmpty ? nil : $0 }, style: op.contains(".") ? .dashed : .solid, start: .none, end: .none)
                    switch op {
                    case "<|--", "<|..": e.start = .triangleHollow
                    case "--|>", "..|>": e.end = .triangleHollow
                    case "*--": e.start = .diamondFilled
                    case "--*": e.end = .diamondFilled
                    case "o--": e.start = .diamondHollow
                    case "--o": e.end = .diamondHollow
                    case "-->", "..>": e.end = .arrow
                    case "<--", "<..": e.start = .arrow
                    default: break
                    }
                    model.edges.append(e)
                    continue
                }
            }
            if let m = member.firstMatch(in: line, range: full) {
                let id = ensure(ns.substring(with: m.range(at: 1)))
                add(id, member: ns.substring(with: m.range(at: 2)))
                continue
            }
            throw MermaidError(line: idx + 1, String(localized: "无法识别的类图语句:\(line.prefix(24))"))
        }
        return model
    }
}
