// @author ixxxxoooo
// 流程类图布局:节点尺寸 → 子图递归(整体视作超级节点)→ 分层布局 → 边裁剪 → 生成场景。

import CoreGraphics
import Foundation

enum FlowLayout {
    static let fontSize = 13.0
    static let labelFontSize = 12.0
    static let subPadding = 16.0
    static let subTitleHeight = 24.0
    static let margin = 20.0

    /// 一层(根或某个子图内部)的布局结果,坐标相对该层左上角。
    private struct Block {
        var size: CGSize
        var nodeRects: [String: CGRect] = [:]
        var subRects: [String: CGRect] = [:]
        var routes: [Int: [CGPoint]] = [:]
    }

    private enum Item: Hashable { case node(String), sub(String) }

    /// 生成场景。
    static func scene(for model: FlowModel) -> MScene {
        let ctx = Context(model: model)
        let block = ctx.layout(parent: nil)
        return ctx.assemble(block)
    }

    /// 节点尺寸(依形状与文本)。
    static func nodeSize(_ node: FlowNode) -> CGSize {
        switch node.shape {
        case .startDot: return CGSize(width: 18, height: 18)
        case .endDot: return CGSize(width: 24, height: 24)
        case .classBox:
            let titleLines = MermaidMetrics.lines(node.text)
            let all = titleLines.map { $0 + "  " } + node.fields + node.methods
            let widest: Double = all.map { MermaidMetrics.width($0, size: 12.5) }.max() ?? 0
            let w = max(90.0, widest + 24.0)
            var h = 38.0 + Double(titleLines.count - 1) * 14.0
            h += Double(node.fields.count) * 18.0
            if !node.methods.isEmpty { h += 10.0 + Double(node.methods.count) * 18.0 }
            return CGSize(width: w, height: max(h, 56))
        default: break
        }
        let t = MermaidMetrics.size(node.text, fontSize: fontSize)
        switch node.shape {
        case .circle, .doubleCircle:
            let d = max(t.width, t.height) + (node.shape == .doubleCircle ? 34 : 24)
            return CGSize(width: max(d, 44), height: max(d, 44))
        case .diamond:
            return CGSize(width: max((t.width + 20) * 1.5, 70), height: max((t.height + 14) * 1.6, 56))
        case .hexagon: return CGSize(width: t.width + 48, height: max(t.height + 20, 40))
        case .stadium: return CGSize(width: t.width + 40, height: max(t.height + 20, 40))
        case .cylinder: return CGSize(width: t.width + 32, height: max(t.height + 34, 52))
        case .parallelogram, .trapezoid, .asymmetric: return CGSize(width: t.width + 48, height: max(t.height + 20, 40))
        default: return CGSize(width: max(t.width + 32, 56), height: max(t.height + 20, 40))
        }
    }

    private final class Context {
        let model: FlowModel
        var sizes: [String: CGSize] = [:]
        var resolved: [(from: String, to: String)?] = []
        var blockCache: [String: Block] = [:]

        init(model: FlowModel) {
            self.model = model
            for (id, node) in model.nodes { sizes[id] = FlowLayout.nodeSize(node) }
            resolved = model.edges.map { e in
                guard let u = model.resolveEndpoint(e.from), let v = model.resolveEndpoint(e.to) else { return nil }
                return (u, v)
            }
        }

        func itemOf(_ node: String, parent: String?) -> Item? {
            let chain = model.chain(of: node)
            if let parent {
                guard let idx = chain.firstIndex(of: parent) else { return nil }
                return idx == 0 ? .node(node) : .sub(chain[idx - 1])
            }
            return chain.isEmpty ? .node(node) : .sub(chain[chain.count - 1])
        }

        /// 本层的节点与子图(保持声明顺序)。
        func children(of parent: String?) -> (nodes: [String], subs: [String]) {
            if let parent, let sub = model.subs[parent] { return (sub.members, sub.children) }
            let nodes = model.nodeOrder.filter { !model.isMember($0) }
            let subs = model.subOrder.filter { model.subs[$0]?.parent == nil }
            return (nodes, subs)
        }

        func layout(parent: String?) -> Block {
            let (nodeIDs, subIDs) = children(of: parent)
            // 子图递归
            var childBlocks: [String: Block] = [:]
            var items: [LayoutNode] = []
            var itemKeys: [Item] = []
            for id in nodeIDs { items.append(LayoutNode(id: "n:" + id, size: sizes[id] ?? CGSize(width: 60, height: 40))); itemKeys.append(.node(id)) }
            for id in subIDs {
                let b = layout(parent: id)
                childBlocks[id] = b
                let title = model.subs[id]?.title ?? ""
                let tw = MermaidMetrics.width(title, size: FlowLayout.labelFontSize) + 32
                let w = max(b.size.width + FlowLayout.subPadding * 2, tw)
                let h = b.size.height + FlowLayout.subPadding * 2 + FlowLayout.subTitleHeight - 8
                items.append(LayoutNode(id: "s:" + id, size: CGSize(width: w, height: h)))
                itemKeys.append(.sub(id))
            }
            // 本层所属的边
            var owned: [Int] = []
            var layoutEdges: [LayoutEdge] = []
            for (i, r) in resolved.enumerated() {
                guard let r, let a = itemOf(r.from, parent: parent), let b = itemOf(r.to, parent: parent) else { continue }
                if a == b, case .sub = a { continue }
                owned.append(i)
                let label = model.edges[i].label.map { text -> CGSize in
                    let s = MermaidMetrics.size(text, fontSize: FlowLayout.labelFontSize)
                    return CGSize(width: s.width + 12, height: s.height + 6)
                }
                layoutEdges.append(LayoutEdge(from: key(a), to: key(b), labelSize: label))
            }
            let result = LayeredLayout.run(nodes: items, edges: layoutEdges, direction: model.direction)
            var block = Block(size: result.size)
            for (n, edgeIndex) in owned.enumerated() { block.routes[edgeIndex] = result.routes[n] }
            for (k, item) in itemKeys.enumerated() {
                guard let rect = result.rects[items[k].id] else { continue }
                switch item {
                case .node(let id): block.nodeRects[id] = rect
                case .sub(let id):
                    block.subRects[id] = rect
                    guard let child = childBlocks[id] else { continue }
                    let dx = rect.minX + (rect.width - child.size.width) / 2
                    let dy = rect.minY + FlowLayout.subPadding + FlowLayout.subTitleHeight - 8
                    for (nid, r) in child.nodeRects { block.nodeRects[nid] = r.offsetBy(dx: dx, dy: dy) }
                    for (sid, r) in child.subRects { block.subRects[sid] = r.offsetBy(dx: dx, dy: dy) }
                    for (e, pts) in child.routes { block.routes[e] = pts.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
                }
            }
            return block
        }

        func key(_ item: Item) -> String {
            switch item { case .node(let id): "n:" + id; case .sub(let id): "s:" + id }
        }

        // MARK: 装配

        func assemble(_ block: Block) -> MScene {
            var items: [MItem] = []
            var bounds = CGRect.null
            func grow(_ r: CGRect) { bounds = bounds.isNull ? r : bounds.union(r) }
            for r in block.nodeRects.values { grow(r) }
            for r in block.subRects.values { grow(r) }

            // 子图(外层先画)
            func depth(_ id: String) -> Int { var d = 0; var c = model.subs[id]?.parent; while let p = c { d += 1; c = model.subs[p]?.parent }; return d }
            for id in block.subRects.keys.sorted(by: { depth($0) < depth($1) }) {
                guard let rect = block.subRects[id], let sub = model.subs[id] else { continue }
                items.append(.rect(rect, fill: .groupFill, stroke: .groupStroke, radius: 8, dashed: false))
                items.append(.text(sub.title, at: CGPoint(x: rect.minX + 12, y: rect.minY + 14), anchor: .leading, size: FlowLayout.labelFontSize, bold: true, color: .subtleText, background: false))
            }

            // 边
            var labels: [MItem] = []
            // 同一对端点之间的多条边(含互为反向)相互错开,避免完全重合
            var pairCount: [String: Int] = [:]
            var pairSeen: [String: Int] = [:]
            func pairKey(_ i: Int) -> String? {
                guard let r = resolved[i], r.from != r.to else { return nil }
                return r.from < r.to ? r.from + "\u{1}" + r.to : r.to + "\u{1}" + r.from
            }
            var pairLabelWidth: [String: Double] = [:]
            for i in model.edges.indices {
                guard let k = pairKey(i) else { continue }
                pairCount[k, default: 0] += 1
                let w = model.edges[i].label.map { MermaidMetrics.width($0, size: FlowLayout.labelFontSize) + 14 } ?? 0
                pairLabelWidth[k] = max(pairLabelWidth[k] ?? 0, w)
            }
            for (i, edge) in model.edges.enumerated() {
                guard var pts = block.routes[i], pts.count >= 2, let r = resolved[i] else { continue }
                let selfLoop = r.from == r.to
                if !selfLoop {
                    // 端点若是子图本身,裁剪到子图边框;否则裁剪到节点形状
                    func target(_ name: String, _ resolvedID: String) -> (CGRect, MShape)? {
                        if model.nodes[name] == nil, let rect = block.subRects[name] { return (rect, .rect) }
                        guard let rect = block.nodeRects[resolvedID], let node = model.nodes[resolvedID] else { return nil }
                        return (rect, node.shape)
                    }
                    if let (a, shape) = target(edge.from, r.from) {
                        pts[0] = clip(center: CGPoint(x: a.midX, y: a.midY), toward: pts[1], rect: a, shape: shape)
                    }
                    if let (b, shape) = target(edge.to, r.to) {
                        pts[pts.count - 1] = clip(center: CGPoint(x: b.midX, y: b.midY), toward: pts[pts.count - 2], rect: b, shape: shape)
                    }
                }
                if let k = pairKey(i), let n = pairCount[k], n > 1, let r = resolved[i] {
                    let seen = pairSeen[k, default: 0]
                    pairSeen[k] = seen + 1
                    // 以规范方向(小 ID → 大 ID)求法线,保证反向边落在相反侧
                    let canonical = r.from < r.to
                    let a = pts[canonical ? 0 : pts.count - 1], b = pts[canonical ? pts.count - 1 : 0]
                    let len = max(hypot(b.x - a.x, b.y - a.y), 1)
                    let nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len
                    let offset = (Double(seen) - Double(n - 1) / 2) * max(16, pairLabelWidth[k] ?? 0)
                    pts = pts.map { CGPoint(x: $0.x + nx * offset, y: $0.y + ny * offset) }
                }
                items.append(.path(points: pts, style: edge.style, start: edge.start, end: edge.end, color: .edge))
                for p in pts { grow(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
                if let text = edge.label, !text.isEmpty {
                    let mid = midpoint(pts)
                    let s = MermaidMetrics.size(text, fontSize: FlowLayout.labelFontSize)
                    grow(CGRect(x: mid.x - s.width / 2, y: mid.y - s.height / 2, width: s.width, height: s.height))
                    labels.append(.text(text, at: mid, anchor: .center, size: FlowLayout.labelFontSize, bold: false, color: .subtleText, background: true))
                }
            }

            // 节点
            for id in model.nodeOrder {
                guard let rect = block.nodeRects[id], let node = model.nodes[id] else { continue }
                switch node.shape {
                case .classBox:
                    items.append(.classCompartments(rect: rect, title: node.text, fields: node.fields, methods: node.methods))
                case .startDot:
                    items.append(.shape(.startDot, rect: rect, text: "", fill: .text, stroke: .text))
                case .endDot:
                    items.append(.shape(.endDot, rect: rect, text: "", fill: .text, stroke: .text))
                default:
                    items.append(.shape(node.shape, rect: rect, text: node.text, fill: .nodeFill, stroke: .nodeStroke))
                }
            }
            items.append(contentsOf: labels)

            if bounds.isNull { bounds = .zero }
            let m = FlowLayout.margin
            let dx = m - bounds.minX, dy = m - bounds.minY
            let shifted = items.map { translate($0, dx: dx, dy: dy) }
            var rects: [String: CGRect] = [:]
            for (id, r) in block.nodeRects { rects[id] = r.offsetBy(dx: dx, dy: dy) }
            return MScene(size: CGSize(width: bounds.width + m * 2, height: bounds.height + m * 2), items: shifted, nodeRects: rects)
        }
    }

    /// 折线按长度取中点。
    static func midpoint(_ pts: [CGPoint]) -> CGPoint {
        var total = 0.0
        for k in 1..<pts.count { total += hypot(pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y) }
        var remain = total / 2
        for k in 1..<pts.count {
            let seg = hypot(pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y)
            if remain <= seg, seg > 0 {
                let t = remain / seg
                return CGPoint(x: pts[k - 1].x + (pts[k].x - pts[k - 1].x) * t, y: pts[k - 1].y + (pts[k].y - pts[k - 1].y) * t)
            }
            remain -= seg
        }
        return pts[pts.count / 2]
    }

    /// 把从节点中心指向 `toward` 的射线裁剪到形状边界。
    static func clip(center: CGPoint, toward p: CGPoint, rect: CGRect, shape: MShape) -> CGPoint {
        let dx = p.x - center.x, dy = p.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let hw = rect.width / 2, hh = rect.height / 2
        var t: Double
        switch shape {
        case .circle, .doubleCircle, .startDot, .endDot:
            t = 1 / sqrt((dx / hw) * (dx / hw) + (dy / hh) * (dy / hh))
        case .diamond:
            t = 1 / (abs(dx) / hw + abs(dy) / hh)
        default:
            let tx = dx == 0 ? Double.infinity : hw / abs(dx)
            let ty = dy == 0 ? Double.infinity : hh / abs(dy)
            t = min(tx, ty)
        }
        return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }

    /// 平移绘制项。
    static func translate(_ item: MItem, dx: Double, dy: Double) -> MItem {
        func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x + dx, y: q.y + dy) }
        switch item {
        case let .shape(s, rect, text, fill, stroke): return .shape(s, rect: rect.offsetBy(dx: dx, dy: dy), text: text, fill: fill, stroke: stroke)
        case let .path(points, style, start, end, color): return .path(points: points.map(p), style: style, start: start, end: end, color: color)
        case let .text(t, at, anchor, size, bold, color, bg): return .text(t, at: p(at), anchor: anchor, size: size, bold: bold, color: color, background: bg)
        case let .rect(r, fill, stroke, radius, dashed): return .rect(r.offsetBy(dx: dx, dy: dy), fill: fill, stroke: stroke, radius: radius, dashed: dashed)
        case let .slice(c, r, a, b, color): return .slice(center: p(c), radius: r, from: a, to: b, color: color)
        case let .line(a, b, style, color): return .line(p(a), p(b), style: style, color: color)
        case let .dot(c, r, fill, stroke): return .dot(center: p(c), radius: r, fill: fill, stroke: stroke)
        case let .classCompartments(rect, title, fields, methods): return .classCompartments(rect: rect.offsetBy(dx: dx, dy: dy), title: title, fields: fields, methods: methods)
        }
    }
}
