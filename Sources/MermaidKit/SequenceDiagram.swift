// @author ygw
// sequenceDiagram:解析 + 布局(直接生成场景)。

import CoreGraphics
import Foundation

struct SeqParticipant: Equatable {
    var id: String
    var label: String
    var isActor: Bool
}

enum SeqEvent: Equatable {
    case message(from: String, to: String, text: String, dashed: Bool, head: MArrow, activate: Bool, deactivate: Bool)
    case note(side: String, ids: [String], text: String)
    case activate(String)
    case deactivate(String)
    case blockStart(kind: String, label: String)
    case blockElse(kind: String, label: String)
    case blockEnd
}

struct SequenceModel: Equatable {
    var participants: [SeqParticipant] = []
    var events: [SeqEvent] = []
    var autonumber = false

    mutating func ensure(_ id: String) {
        if !participants.contains(where: { $0.id == id }) { participants.append(SeqParticipant(id: id, label: id, isActor: false)) }
    }
}

enum SequenceParser {
    static func parse(_ lines: [String]) throws -> SequenceModel {
        var model = SequenceModel()
        let message = try NSRegularExpression(pattern: #"^(.+?)\s*(<<-->>|<<->>|-->>|->>|--x|-x|--\)|-\)|-->|->)\s*([+-])?\s*([^:]+?)\s*:\s*(.*)$"#)
        let note = try NSRegularExpression(pattern: #"^note\s+(right of|left of|over)\s+([^:]+?)\s*:\s*(.*)$"#, options: .caseInsensitive)
        let decl = try NSRegularExpression(pattern: #"^(participant|actor)\s+(\S+?)(?:\s+as\s+(.+))?$"#)
        let blockKinds = ["loop", "alt", "opt", "par", "critical", "break", "rect", "box"]
        var stack: [String] = []

        for (idx, raw) in lines.enumerated() where idx > 0 {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue }
            let lower = line.lowercased()
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            func cap(_ m: NSTextCheckingResult, _ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }

            if lower == "autonumber" { model.autonumber = true; continue }
            if lower.hasPrefix("title") || lower.hasPrefix("link ") || lower.hasPrefix("links ") { continue }
            if lower == "end" {
                if stack.popLast() != "box" { model.events.append(.blockEnd) }
                continue
            }
            if let m = decl.firstMatch(in: line, range: full), let kind = cap(m, 1), let id = cap(m, 2) {
                let label = cap(m, 3).map(FlowchartParser.unquote) ?? id
                if let i = model.participants.firstIndex(where: { $0.id == id }) {
                    model.participants[i].label = label; model.participants[i].isActor = kind == "actor"
                } else {
                    model.participants.append(SeqParticipant(id: id, label: label, isActor: kind == "actor"))
                }
                continue
            }
            if lower.hasPrefix("activate ") { let id = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces); model.ensure(id); model.events.append(.activate(id)); continue }
            if lower.hasPrefix("deactivate ") { let id = String(line.dropFirst(11)).trimmingCharacters(in: .whitespaces); model.ensure(id); model.events.append(.deactivate(id)); continue }
            if let m = note.firstMatch(in: line, range: full), let side = cap(m, 1), let who = cap(m, 2), let text = cap(m, 3) {
                let ids = who.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                ids.forEach { model.ensure($0) }
                model.events.append(.note(side: side.lowercased(), ids: ids, text: text))
                continue
            }
            if let kind = blockKinds.first(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
                stack.append(kind)
                if kind != "box" { model.events.append(.blockStart(kind: kind, label: String(line.dropFirst(kind.count)).trimmingCharacters(in: .whitespaces))) }
                continue
            }
            if ["else", "and", "option"].contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
                let word = lower.split(separator: " ").first.map(String.init) ?? "else"
                model.events.append(.blockElse(kind: word, label: String(line.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let m = message.firstMatch(in: line, range: full), let a = cap(m, 1), let op = cap(m, 2), let b = cap(m, 4) {
                let flag = cap(m, 3)
                model.ensure(a); model.ensure(b)
                let head: MArrow
                switch op {
                case "->>", "-->>", "<<->>", "<<-->>": head = .arrow
                case "-x", "--x": head = .cross
                case "-)", "--)": head = .circle
                default: head = .none
                }
                model.events.append(.message(from: a, to: b, text: cap(m, 5) ?? "", dashed: op.hasPrefix("--") || op == "<<-->>", head: head, activate: flag == "+", deactivate: flag == "-"))
                continue
            }
            throw MermaidError(line: idx + 1, "无法识别的时序图语句:\(line.prefix(24))")
        }
        return model
    }
}

enum SequenceLayout {
    static let font = 13.0
    static let rowHeight = 34.0
    static let headerHeight = 36.0
    static let margin = 20.0

    static func scene(for model: SequenceModel) -> MScene {
        let ps = model.participants
        guard !ps.isEmpty else { return MScene(size: CGSize(width: 40, height: 40), items: []) }
        var index: [String: Int] = [:]
        for (i, p) in ps.enumerated() { index[p.id] = i }
        let headerW = ps.map { max(MermaidMetrics.width($0.label, size: font) + 28, 84) }

        // 相邻间距
        var gaps = (0..<max(ps.count - 1, 0)).map { max((headerW[$0] + headerW[$0 + 1]) / 2 + 24, 130) }
        var rightExtra = 0.0
        struct Need { var lo: Int; var hi: Int; var width: Double }
        var needs: [Need] = []
        var number = 0
        for event in model.events {
            switch event {
            case let .message(from, to, text, _, _, _, _):
                guard let a = index[from], let b = index[to] else { continue }
                let label = (model.autonumber ? "\(number + 1). " : "") + text
                number += 1
                let w = MermaidMetrics.width(label, size: 12) + 36
                if a == b { if a == ps.count - 1 { rightExtra = max(rightExtra, w + 20) } else { needs.append(Need(lo: a, hi: a + 1, width: w + 40)) } }
                else { needs.append(Need(lo: min(a, b), hi: max(a, b), width: w)) }
            case let .note(side, ids, text):
                let w = MermaidMetrics.size(text, fontSize: 12).width + 28
                let idxs = ids.compactMap { index[$0] }
                guard let first = idxs.min(), let last = idxs.max() else { continue }
                if side == "over" {
                    if first != last { needs.append(Need(lo: first, hi: last, width: w)) }
                } else if side == "right of" {
                    if last < ps.count - 1 { needs.append(Need(lo: last, hi: last + 1, width: w + headerW[last] / 2 )) } else { rightExtra = max(rightExtra, w + 20) }
                } else if first > 0 { needs.append(Need(lo: first - 1, hi: first, width: w + headerW[first] / 2)) }
            default: break
            }
        }
        for need in needs.sorted(by: { ($0.hi - $0.lo) < ($1.hi - $1.lo) }) where need.hi > need.lo {
            let current = gaps[need.lo..<need.hi].reduce(0, +)
            if current < need.width {
                let add = (need.width - current) / Double(need.hi - need.lo)
                for k in need.lo..<need.hi { gaps[k] += add }
            }
        }
        var xs: [Double] = [headerW[0] / 2]
        for g in gaps { xs.append(xs[xs.count - 1] + g) }
        let leftPad = 0.0

        var items: [MItem] = []
        var y = headerHeight + 22
        var activations: [String: [Double]] = [:]
        var blockStack: [(kind: String, label: String, startY: Double, dividers: [(Double, String)])] = []
        var drawnActivations: [MItem] = []
        var frames: [MItem] = []
        var body: [MItem] = []
        number = 0

        func closeActivation(_ id: String, at yy: Double) {
            guard let start = activations[id]?.popLast(), let i = index[id] else { return }
            let depth = Double(activations[id]?.count ?? 0)
            drawnActivations.append(.rect(CGRect(x: xs[i] - 5 + depth * 4, y: start, width: 10, height: max(yy - start, 6)), fill: .activation, stroke: .nodeStroke, radius: 1, dashed: false))
        }

        for event in model.events {
            switch event {
            case let .message(from, to, text, dashed, head, activate, deactivate):
                guard let a = index[from], let b = index[to] else { continue }
                number += 1
                let label = (model.autonumber ? "\(number). " : "") + text
                let style: MLineStyle = dashed ? .dashed : .solid
                if a == b {
                    let x = xs[a] + (Double(activations[from]?.count ?? 0) * 4)
                    let pts = [CGPoint(x: x, y: y + 10), CGPoint(x: x + 36, y: y + 10), CGPoint(x: x + 36, y: y + 28), CGPoint(x: x, y: y + 28)]
                    body.append(.path(points: pts, style: style, start: .none, end: head == .none ? .arrow : head, color: .edge))
                    body.append(.text(label, at: CGPoint(x: x + 44, y: y + 19), anchor: .leading, size: 12, bold: false, color: .text, background: false))
                    if activate { activations[to, default: []].append(y + 24) }
                    if deactivate { closeActivation(from, at: y + 28) }
                    y += rowHeight + 10
                } else {
                    let dir: Double = b > a ? 1 : -1
                    let sx = xs[a] + dir * (Double(activations[from]?.count ?? 0) > 0 ? 5 : 0)
                    let ex = xs[b] - dir * (Double(activations[to]?.count ?? 0) > 0 || activate ? 5 : 0)
                    let ly = y + rowHeight - 6
                    body.append(.text(label, at: CGPoint(x: (sx + ex) / 2, y: y + 8), anchor: .center, size: 12, bold: false, color: .text, background: false))
                    body.append(.path(points: [CGPoint(x: sx, y: ly), CGPoint(x: ex, y: ly)], style: style, start: .none, end: head == .none ? .arrow : head, color: .edge))
                    if activate { activations[to, default: []].append(ly) }
                    if deactivate { closeActivation(from, at: ly) }
                    y += rowHeight + 4
                }
            case let .note(side, ids, text):
                let idxs = ids.compactMap { index[$0] }
                guard let first = idxs.min(), let last = idxs.max() else { continue }
                let size = MermaidMetrics.size(text, fontSize: 12)
                let w = max(size.width + 24, 64), h = size.height + 14
                var x: Double
                switch side {
                case "right of": x = xs[last] + 12
                case "left of": x = xs[first] - 12 - w
                default: x = (xs[first] + xs[last]) / 2 - w / 2; if first != last { x = min(x, xs[first] - 8); }
                }
                let rectW = side == "over" && first != last ? max(w, xs[last] - xs[first] + 16) : w
                body.append(.rect(CGRect(x: x, y: y, width: rectW, height: h), fill: .noteFill, stroke: .nodeStroke, radius: 3, dashed: false))
                body.append(.text(text, at: CGPoint(x: x + rectW / 2, y: y + h / 2), anchor: .center, size: 12, bold: false, color: .text, background: false))
                y += h + 12
            case let .activate(id): activations[id, default: []].append(y)
            case let .deactivate(id): closeActivation(id, at: y)
            case let .blockStart(kind, label):
                blockStack.append((kind, label, y, []))
                y += 30
            case let .blockElse(kind, label):
                if !blockStack.isEmpty { blockStack[blockStack.count - 1].dividers.append((y, "[" + (label.isEmpty ? kind : label) + "]")) }
                y += 26
            case .blockEnd:
                guard let block = blockStack.popLast() else { continue }
                let depth = Double(blockStack.count)
                let rect = CGRect(x: -10 + depth * 8 + leftPad, y: block.startY, width: (xs.last ?? 0) + 20 - depth * 16 + rightExtra * 0.5, height: y - block.startY + 4)
                frames.append(.rect(rect, fill: nil, stroke: .nodeStroke, radius: 2, dashed: false))
                let tab = block.kind
                frames.append(.rect(CGRect(x: rect.minX, y: rect.minY, width: MermaidMetrics.width(tab, size: 11) + 18, height: 18), fill: .groupFill, stroke: .nodeStroke, radius: 2, dashed: false))
                frames.append(.text(tab, at: CGPoint(x: rect.minX + 9, y: rect.minY + 9), anchor: .leading, size: 11, bold: true, color: .text, background: false))
                if !block.label.isEmpty {
                    frames.append(.text("[" + block.label + "]", at: CGPoint(x: rect.minX + MermaidMetrics.width(tab, size: 11) + 28, y: rect.minY + 9), anchor: .leading, size: 11, bold: false, color: .subtleText, background: false))
                }
                for (dy, text) in block.dividers {
                    frames.append(.line(CGPoint(x: rect.minX, y: dy), CGPoint(x: rect.maxX, y: dy), style: .dashed, color: .nodeStroke))
                    frames.append(.text(text, at: CGPoint(x: rect.minX + 10, y: dy + 11), anchor: .leading, size: 11, bold: false, color: .subtleText, background: false))
                }
                y += 10
            }
        }
        for (id, _) in activations { while !(activations[id]?.isEmpty ?? true) { closeActivation(id, at: y) } }
        while let block = blockStack.popLast() { _ = block }
        let bottom = y + 8

        // 生命线与头部
        for (i, p) in ps.enumerated() {
            items.append(.line(CGPoint(x: xs[i], y: headerHeight), CGPoint(x: xs[i], y: bottom), style: .dashed, color: .nodeStroke))
            _ = p
        }
        items.append(contentsOf: frames)
        items.append(contentsOf: drawnActivations)
        items.append(contentsOf: body)
        var rects: [String: CGRect] = [:]
        for (i, p) in ps.enumerated() {
            for top in [0.0, bottom] {
                let rect = CGRect(x: xs[i] - headerW[i] / 2, y: top, width: headerW[i], height: headerHeight)
                items.append(.shape(p.isActor ? .stadium : .rounded, rect: rect, text: p.label, fill: .nodeFill, stroke: .nodeStroke))
                if top == 0 { rects[p.id] = rect }
            }
        }
        let width = (xs.last ?? 0) + (headerW.last ?? 0) / 2 + rightExtra
        let height = bottom + headerHeight
        let m = margin
        let dx = m + 10
        let shifted = items.map { FlowLayout.translate($0, dx: dx, dy: m) }
        return MScene(size: CGSize(width: width + m * 2 + 20, height: height + m * 2), items: shifted, nodeRects: rects.mapValues { $0.offsetBy(dx: dx, dy: m) })
    }
}
