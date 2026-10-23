// @author ixxxxoooo
// 文本缓冲:持久化(不可变)B 树绳结构,偏移为 UTF-16,统一以 `\n` 作换行(EOL 在 `EditorDocument` 装载时归一)。
// 设计要点:
// - 叶子存最多 `leafMax` 个 UTF-16 单元,内部节点最多 `maxChildren` 个子节点,所有叶子深度一致;
// - 每个节点缓存「长度」与「换行数」,插入/删除/按行定位均为 O(log n);
// - 节点创建后不可变,编辑走路径复制,因此 `TextRope` 值拷贝是 O(1) 的不可变快照,后台任务可无锁读取;
// - 大块粘贴一次性切成叶子再自底向上打包,不会逐字符退化。
//
// 这是计划里的 `PieceTree` 的实际落点:相同的复杂度与快照语义,但实现更简单、更易验证。

import Foundation

/// 绳节点:叶子持有文本块,内部节点持有子节点。创建后不可变,因此可跨线程共享。
final class RopeNode: @unchecked Sendable {
    // 不可变值,线程安全依赖「构造后不再修改」的约定。
    let length: Int
    let lineBreaks: Int
    let height: Int
    let chunk: ContiguousArray<UInt16>
    let children: ContiguousArray<RopeNode>

    /// 叶子节点。
    init(leaf chunk: ContiguousArray<UInt16>) {
        self.chunk = chunk
        self.children = []
        self.height = 0
        self.length = chunk.count
        var breaks = 0
        chunk.withUnsafeBufferPointer { buffer in
            for unit in buffer where unit == 10 { breaks += 1 }
        }
        self.lineBreaks = breaks
    }

    /// 内部节点;`children` 必须非空且高度一致。
    init(children: ContiguousArray<RopeNode>) {
        self.chunk = []
        self.children = children
        self.height = (children.first?.height ?? -1) + 1
        var totalLength = 0
        var totalBreaks = 0
        for child in children {
            totalLength += child.length
            totalBreaks += child.lineBreaks
        }
        self.length = totalLength
        self.lineBreaks = totalBreaks
    }

    var isLeaf: Bool { height == 0 }
}

/// 绳的调参常量。
enum RopeTuning {
    /// 叶子允许的最大 UTF-16 单元数,超过则切分。
    static let leafMax = 2048
    /// 切分与合并的目标叶子大小。
    static let leafTarget = 1024
    /// 内部节点最大子节点数。
    static let maxChildren = 32
}

/// 不可变文本快照:值语义、O(1) 拷贝、可跨线程读取。
public struct TextRope: Sendable {
    let root: RopeNode

    /// 空文本。
    public init() { self.root = RopeNode(leaf: []) }

    init(root: RopeNode) { self.root = root }

    /// 由 UTF-16 单元整体构建(O(n),用于装载文件)。
    public init(utf16 units: ContiguousArray<UInt16>) {
        self.root = TextRope.build(units)
    }

    /// 由字符串构建(不做换行归一,调用方保证只含 `\n`)。
    public init(_ string: String) {
        self.init(utf16: ContiguousArray(string.utf16))
    }

    /// 总长度(UTF-16)。
    public var length: Int { root.length }
    /// 行数(末尾换行后的空行也计入,至少为 1)。
    public var lineCount: Int { root.lineBreaks + 1 }
    /// 是否为空文本。
    public var isEmpty: Bool { root.length == 0 }

    // MARK: 构建与编辑

    /// 把一段 UTF-16 切成叶子并打包成树根。
    private static func build(_ units: ContiguousArray<UInt16>) -> RopeNode {
        normalize(leaves(from: units))
    }

    /// 把文本切成若干叶子(空文本给一个空叶子)。
    static func leaves(from units: ContiguousArray<UInt16>) -> [RopeNode] {
        if units.count <= RopeTuning.leafMax { return [RopeNode(leaf: units)] }
        var result: [RopeNode] = []
        result.reserveCapacity(units.count / RopeTuning.leafTarget + 1)
        var start = 0
        while start < units.count {
            let end = min(start + RopeTuning.leafTarget, units.count)
            result.append(RopeNode(leaf: ContiguousArray(units[start..<end])))
            start = end
        }
        return result
    }

    /// 把同高度的一组节点打包为上一层(超过 `maxChildren` 时均匀分组)。
    static func packLevel(_ nodes: [RopeNode]) -> [RopeNode] {
        let maxChildren = RopeTuning.maxChildren
        if nodes.count <= maxChildren { return [RopeNode(children: ContiguousArray(nodes))] }
        let groups = (nodes.count + maxChildren - 1) / maxChildren
        let base = nodes.count / groups
        let extra = nodes.count % groups
        var result: [RopeNode] = []
        result.reserveCapacity(groups)
        var index = 0
        for group in 0..<groups {
            let size = base + (group < extra ? 1 : 0)
            result.append(RopeNode(children: ContiguousArray(nodes[index..<(index + size)])))
            index += size
        }
        return result
    }

    /// 把同高度节点列表归并为唯一树根,并折叠只有单子节点的根链。
    static func normalize(_ nodes: [RopeNode]) -> RopeNode {
        guard !nodes.isEmpty else { return RopeNode(leaf: []) }
        var level = nodes
        while level.count > 1 { level = packLevel(level) }
        var root = level[0]
        while !root.isLeaf, root.children.count == 1 { root = root.children[0] }
        return root
    }

    /// 在 `offset` 处插入文本(超界夹取)。
    public func inserting(_ text: ContiguousArray<UInt16>, at offset: Int) -> TextRope {
        if text.isEmpty { return self }
        let position = min(max(offset, 0), length)
        return TextRope(root: TextRope.normalize(TextRope.insert(root, at: position, text)))
    }

    /// 删除区间(超界夹取)。
    public func deleting(_ range: TextRange) -> TextRope {
        let lower = min(range.location, length)
        let upper = min(range.upperBound, length)
        if upper <= lower { return self }
        return TextRope(root: TextRope.normalize(TextRope.delete(root, from: lower, to: upper)))
    }

    /// 用 `text` 替换区间(超界夹取)。
    public func replacing(_ range: TextRange, with text: ContiguousArray<UInt16>) -> TextRope {
        let lower = min(range.location, length)
        let upper = min(range.upperBound, length)
        return deleting(TextRange(lower: lower, upper: upper)).inserting(text, at: lower)
    }

    /// 递归插入:返回替代 `node` 的同高度节点序列(叶子过大或内部节点过满时会分裂成多个)。
    private static func insert(_ node: RopeNode, at offset: Int, _ text: ContiguousArray<UInt16>) -> [RopeNode] {
        if node.isLeaf {
            var merged = ContiguousArray<UInt16>()
            merged.reserveCapacity(node.length + text.count)
            merged.append(contentsOf: node.chunk[0..<offset])
            merged.append(contentsOf: text)
            merged.append(contentsOf: node.chunk[offset...])
            return leaves(from: merged)
        }
        var index = 0
        var base = 0
        let lastIndex = node.children.count - 1
        while index < lastIndex, offset > base + node.children[index].length {
            base += node.children[index].length
            index += 1
        }
        let replaced = insert(node.children[index], at: offset - base, text)
        var newChildren: [RopeNode] = []
        newChildren.reserveCapacity(node.children.count + replaced.count)
        newChildren.append(contentsOf: node.children[0..<index])
        newChildren.append(contentsOf: replaced)
        newChildren.append(contentsOf: node.children[(index + 1)...])
        return packLevel(newChildren)
    }

    /// 递归删除 `[from, to)`(相对 `node` 的偏移):返回 0 个或 1 个替代节点。
    private static func delete(_ node: RopeNode, from lower: Int, to upper: Int) -> [RopeNode] {
        if lower <= 0, upper >= node.length { return [] }
        if node.isLeaf {
            var rest = ContiguousArray<UInt16>()
            rest.reserveCapacity(node.length - (upper - lower))
            rest.append(contentsOf: node.chunk[0..<lower])
            rest.append(contentsOf: node.chunk[upper...])
            return [RopeNode(leaf: rest)]
        }
        var kept: [RopeNode] = []
        kept.reserveCapacity(node.children.count)
        var start = 0
        for child in node.children {
            let end = start + child.length
            if end <= lower || start >= upper {
                kept.append(child)
            } else {
                let childLower = max(lower, start) - start
                let childUpper = min(upper, end) - start
                kept.append(contentsOf: delete(child, from: childLower, to: childUpper))
            }
            start = end
        }
        if kept.isEmpty { return [] }
        if node.height == 1 { kept = mergeSmallLeaves(kept) }
        return [RopeNode(children: ContiguousArray(kept))]
    }

    /// 合并相邻的过小叶子,避免大量小删除后叶子碎片化。
    private static func mergeSmallLeaves(_ leaves: [RopeNode]) -> [RopeNode] {
        var merged: [RopeNode] = []
        merged.reserveCapacity(leaves.count)
        for leaf in leaves {
            if let last = merged.last, last.length + leaf.length <= RopeTuning.leafTarget {
                var combined = last.chunk
                combined.append(contentsOf: leaf.chunk)
                merged[merged.count - 1] = RopeNode(leaf: combined)
            } else {
                merged.append(leaf)
            }
        }
        return merged
    }
}
