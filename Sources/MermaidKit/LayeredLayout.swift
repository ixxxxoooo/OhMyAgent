// @author ixxxxoooo
// 分层图布局(Sugiyama 简化版):破环 → 最长路径分层 → 长边插入虚拟节点 → 重心法减少交叉 → 坐标分配。
// 输出与方向无关的「沿层方向/跨层方向」坐标,再按 TB/BT/LR/RL 映射为屏幕坐标。

import CoreGraphics
import Foundation

/// 布局方向。
public enum MDirection: String, Sendable {
    case topDown = "TB", bottomUp = "BT", leftRight = "LR", rightLeft = "RL"

    /// 从 Mermaid 声明解析(TD 等价于 TB)。
    public init?(token: String) {
        switch token.uppercased() {
        case "TD", "TB": self = .topDown
        case "BT": self = .bottomUp
        case "LR": self = .leftRight
        case "RL": self = .rightLeft
        default: return nil
        }
    }

    var isHorizontal: Bool { self == .leftRight || self == .rightLeft }
}

/// 布局输入节点。
struct LayoutNode {
    var id: String
    var size: CGSize
}

/// 布局输入边。
struct LayoutEdge {
    var from: String
    var to: String
    /// 边标签尺寸(无标签为 nil),用于给长边的中间虚拟节点预留空间
    var labelSize: CGSize?
}

/// 布局结果。
struct LayoutResult {
    var rects: [String: CGRect]
    /// 与输入边同序的折线(含两端节点中心,尚未按边界裁剪)
    var routes: [[CGPoint]]
    var size: CGSize
}

enum LayeredLayout {
    /// 计算布局。
    /// - Parameters:
    ///   - nodes: 节点(顺序即初始排序依据)
    ///   - edges: 边
    ///   - direction: 方向
    ///   - nodeGap: 同层节点间距
    ///   - layerGap: 层间距
    static func run(nodes: [LayoutNode], edges: [LayoutEdge], direction: MDirection, nodeGap: Double = 36, layerGap: Double = 48) -> LayoutResult {
        guard !nodes.isEmpty else { return LayoutResult(rects: [:], routes: [], size: CGSize(width: 0, height: 0)) }
        let horizontal = direction.isHorizontal
        var index: [String: Int] = [:]
        for (i, node) in nodes.enumerated() { index[node.id] = i }
        // 沿层方向(along)与跨层方向(across)的节点尺寸
        var along = nodes.map { horizontal ? $0.size.width : $0.size.height }
        var across = nodes.map { horizontal ? $0.size.height : $0.size.width }

        // 1. 边规整:去掉自环与未知节点;反向边破环
        struct E { var u: Int; var v: Int; var reversed: Bool; var original: Int }
        var kept: [E] = []
        for (i, edge) in edges.enumerated() {
            guard let u = index[edge.from], let v = index[edge.to], u != v else { continue }
            kept.append(E(u: u, v: v, reversed: false, original: i))
        }
        let reversedFlags = breakCycles(count: nodes.count, edges: kept.map { ($0.u, $0.v) })
        for i in kept.indices where reversedFlags[i] {
            kept[i] = E(u: kept[i].v, v: kept[i].u, reversed: true, original: kept[i].original)
        }

        // 2. 最长路径分层 + 源点下拉
        var layer = longestPathLayers(count: nodes.count, edges: kept.map { ($0.u, $0.v) })

        // 3. 虚拟节点
        var routes: [[Int]] = []
        var layers: [[Int]] = []
        func ensureLayer(_ l: Int) { while layers.count <= l { layers.append([]) } }
        for i in nodes.indices { ensureLayer(layer[i]); layers[layer[i]].append(i) }
        var labelDummy: [Int: CGSize] = [:]
        var edgeRoutes: [(route: [Int], reversed: Bool, original: Int)] = []
        for e in kept {
            var route = [e.u]
            let span = layer[e.v] - layer[e.u]
            if span > 1 {
                for step in 1..<span {
                    let id = along.count
                    along.append(8); across.append(8)
                    layer.append(layer[e.u] + step)
                    ensureLayer(layer[e.u] + step)
                    layers[layer[e.u] + step].append(id)
                    route.append(id)
                }
                if let label = edges[e.original].labelSize {
                    let mid = route[route.count / 2]
                    labelDummy[mid] = label
                    across[mid] = max(across[mid], horizontal ? label.height : label.width)
                    along[mid] = max(along[mid], horizontal ? label.width : label.height)
                }
            }
            route.append(e.v)
            edgeRoutes.append((route, e.reversed, e.original))
            routes.append(route)
        }

        // 邻接(用于排序与定位)
        var up = Array(repeating: [Int](), count: along.count), down = up
        for route in routes {
            for k in 0..<(route.count - 1) {
                down[route[k]].append(route[k + 1])
                up[route[k + 1]].append(route[k])
            }
        }

        // 4. 重心法排序
        var position = [Int](repeating: 0, count: along.count)
        func refreshPositions() {
            for l in layers.indices { for (p, n) in layers[l].enumerated() { position[n] = p } }
        }
        refreshPositions()
        for sweep in 0..<8 {
            let downward = sweep % 2 == 0
            let range = downward ? Array(1..<max(layers.count, 1)) : Array((0..<max(layers.count - 1, 0)).reversed())
            for l in range where l < layers.count {
                let neighbors = downward ? up : down
                let keyed = layers[l].map { n -> (Int, Double) in
                    let ns = neighbors[n]
                    let key = ns.isEmpty ? Double(position[n]) : ns.map { Double(position[$0]) }.reduce(0, +) / Double(ns.count)
                    return (n, key)
                }
                layers[l] = keyed.enumerated().sorted { a, b in
                    a.element.1 == b.element.1 ? a.offset < b.offset : a.element.1 < b.element.1
                }.map { $0.element.0 }
                for (p, n) in layers[l].enumerated() { position[n] = p }
            }
        }

        // 5. 坐标:沿层方向累计,跨层方向用「期望位置 + 推挤」迭代
        let hasLabels = edges.contains { $0.labelSize != nil }
        let gap = layerGap + (hasLabels ? 16 : 0)
        var alongPos = [Double](repeating: 0, count: along.count)
        var cursor = 0.0
        for l in layers.indices {
            let thickness = layers[l].map { along[$0] }.max() ?? 0
            for n in layers[l] { alongPos[n] = cursor + thickness / 2 }
            cursor += thickness + gap
        }
        let totalAlong = max(cursor - gap, 0)

        var acrossPos = [Double](repeating: 0, count: along.count)
        func separation(_ a: Int, _ b: Int) -> Double {
            let dummyPair = a >= nodes.count && b >= nodes.count
            let g = dummyPair ? nodeGap / 2 : nodeGap
            return (across[a] + across[b]) / 2 + g
        }
        for l in layers.indices {
            var x = 0.0
            for (i, n) in layers[l].enumerated() {
                if i > 0 { x += separation(layers[l][i - 1], n) }
                acrossPos[n] = x
            }
        }
        for iteration in 0..<8 {
            let downward = iteration % 2 == 0
            let order = downward ? Array(layers.indices) : Array(layers.indices.reversed())
            for l in order {
                let neighbors = downward ? up : down
                var desired: [Double] = layers[l].map { n in
                    let ns = neighbors[n] + (iteration > 3 ? (downward ? down[n] : up[n]) : [])
                    return ns.isEmpty ? acrossPos[n] : ns.map { acrossPos[$0] }.reduce(0, +) / Double(ns.count)
                }
                // 前向推挤保证不重叠,再整体平移使平均偏差最小
                var placed = desired
                for i in placed.indices where i > 0 {
                    placed[i] = max(placed[i], placed[i - 1] + separation(layers[l][i - 1], layers[l][i]))
                }
                let shift = zip(desired, placed).map { $0 - $1 }.reduce(0, +) / Double(max(placed.count, 1))
                desired = placed.map { $0 + shift }
                for (i, n) in layers[l].enumerated() { acrossPos[n] = desired[i] }
            }
        }
        let minAcross = layers.flatMap { $0 }.map { acrossPos[$0] - across[$0] / 2 }.min() ?? 0
        let maxAcross = layers.flatMap { $0 }.map { acrossPos[$0] + across[$0] / 2 }.max() ?? 0
        let totalAcross = maxAcross - minAcross
        for i in acrossPos.indices { acrossPos[i] -= minAcross }

        // 6. 映射到屏幕坐标
        func point(_ n: Int) -> CGPoint {
            let a = alongPos[n], c = acrossPos[n]
            switch direction {
            case .topDown: return CGPoint(x: c, y: a)
            case .bottomUp: return CGPoint(x: c, y: totalAlong - a)
            case .leftRight: return CGPoint(x: a, y: c)
            case .rightLeft: return CGPoint(x: totalAlong - a, y: c)
            }
        }
        var rects: [String: CGRect] = [:]
        for (i, node) in nodes.enumerated() {
            let p = point(i)
            rects[node.id] = CGRect(x: p.x - node.size.width / 2, y: p.y - node.size.height / 2, width: node.size.width, height: node.size.height)
        }
        var polylines = [[CGPoint]](repeating: [], count: edges.count)
        for item in edgeRoutes {
            var pts = item.route.map(point)
            if item.reversed { pts.reverse() }
            polylines[item.original] = pts
        }
        for (i, edge) in edges.enumerated() where polylines[i].isEmpty {
            // 自环:在节点右侧画一个小环
            if let u = index[edge.from], edge.from == edge.to, let rect = rects[nodes[u].id] {
                let r = rect
                polylines[i] = [
                    CGPoint(x: r.maxX, y: r.midY - r.height / 4), CGPoint(x: r.maxX + 26, y: r.midY - r.height / 4),
                    CGPoint(x: r.maxX + 26, y: r.midY + r.height / 4), CGPoint(x: r.maxX, y: r.midY + r.height / 4),
                ]
            }
        }
        let size = horizontal ? CGSize(width: totalAlong, height: totalAcross) : CGSize(width: totalAcross, height: totalAlong)
        return LayoutResult(rects: rects, routes: polylines, size: size)
    }

    /// DFS 找回边,返回与输入边同序的「需反向」标志。
    private static func breakCycles(count: Int, edges: [(Int, Int)]) -> [Bool] {
        var adjacency = Array(repeating: [(to: Int, edge: Int)](), count: count)
        for (i, e) in edges.enumerated() { adjacency[e.0].append((e.1, i)) }
        var state = [UInt8](repeating: 0, count: count) // 0 未访问 1 栈中 2 完成
        var reversed = [Bool](repeating: false, count: edges.count)
        for start in 0..<count where state[start] == 0 {
            var stack: [(node: Int, next: Int)] = [(start, 0)]
            state[start] = 1
            while let top = stack.last {
                if top.next < adjacency[top.node].count {
                    stack[stack.count - 1].next += 1
                    let (to, edge) = adjacency[top.node][top.next]
                    if state[to] == 1 { reversed[edge] = true }
                    else if state[to] == 0 { state[to] = 1; stack.append((to, 0)) }
                } else {
                    state[top.node] = 2
                    stack.removeLast()
                }
            }
        }
        return reversed
    }

    /// 最长路径分层;无入边的节点下拉到紧贴其最浅后继,缩短边长。
    private static func longestPathLayers(count: Int, edges: [(Int, Int)]) -> [Int] {
        var indegree = [Int](repeating: 0, count: count)
        var out = Array(repeating: [Int](), count: count)
        for (u, v) in edges { indegree[v] += 1; out[u].append(v) }
        var layer = [Int](repeating: 0, count: count)
        var queue = (0..<count).filter { indegree[$0] == 0 }
        var head = 0
        var topo: [Int] = []
        while head < queue.count {
            let u = queue[head]; head += 1
            topo.append(u)
            for v in out[u] {
                layer[v] = max(layer[v], layer[u] + 1)
                indegree[v] -= 1
                if indegree[v] == 0 { queue.append(v) }
            }
        }
        // 反向遍历:源点贴近后继
        var hasPred = [Bool](repeating: false, count: count)
        for (_, v) in edges { hasPred[v] = true }
        for u in topo.reversed() where !hasPred[u] && !out[u].isEmpty {
            layer[u] = (out[u].map { layer[$0] }.min() ?? 1) - 1
        }
        let minLayer = layer.min() ?? 0
        return layer.map { $0 - minLayer }
    }
}
