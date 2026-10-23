// @author ixxxxoooo
// 装饰集合:诊断、查找命中、括号对、单词高亮、Git/Agent 行改动、inlay、行内 Diff 块等统一用「区间 + 种类」表示。
// 实现:按起点排序的数组 + 前缀最大终点,区间查询为 O(log n + k);编辑后整体平移 O(n)(顺序保持,无需重排)。
// 语法 token 不放这里(按行缓存,见语法层)。

import Foundation

/// 装饰种类。
public enum DecorationKind: Sendable, Hashable {
    case diagnosticError, diagnosticWarning, diagnosticInfo, diagnosticHint
    case findMatch, findCurrent
    case wordHighlight, wordHighlightWrite
    case bracketMatch
    case selectionMatch
    case agentAdded, agentRemoved, agentModified
    case gitAdded, gitModified, gitRemoved
    case link
    /// snippet 占位(非当前 / 当前)。
    case snippetStop, snippetStopActive
    /// 零宽 inlay 文本(类型提示、参数名)。
    case inlay
    /// 幽灵补全文本。
    case ghostText
    /// 自定义:由调用方按 `payload` 解释。
    case custom(Int)
}

/// 一条装饰。
public struct Decoration: Sendable, Hashable, Identifiable {
    /// 唯一标识(调用方分配,用于增删与命中)。
    public var id: Int
    /// 覆盖区间(UTF-16)。
    public var range: TextSpan
    /// 种类。
    public var kind: DecorationKind
    /// 附带文本(诊断消息、inlay 文字、ghost 文本等)。
    public var payload: String?
    /// 区间被整体删除而坍缩为空时是否移除(诊断、查找命中应移除,inlay 保留)。
    public var removesWhenCollapsed: Bool

    public init(id: Int, range: TextSpan, kind: DecorationKind, payload: String? = nil, removesWhenCollapsed: Bool = true) {
        self.id = id
        self.range = range
        self.kind = kind
        self.payload = payload
        self.removesWhenCollapsed = removesWhenCollapsed
    }
}

/// 装饰集合(值类型)。
public struct DecorationSet: Sendable {
    /// 按起点升序(同起点按 id)的装饰。
    public private(set) var items: [Decoration] = []
    /// `maxEnd[i]` = items[0...i] 的最大终点,用于剪枝查询。
    private var maxEnd: [Int] = []

    public init() {}

    /// 装饰数量。
    public var count: Int { items.count }

    /// 用一批装饰整体替换(会排序)。
    public mutating func replaceAll(_ decorations: [Decoration]) {
        items = decorations.sorted { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.id < $1.id }
        rebuildMaxEnd()
    }

    /// 移除某种类的全部装饰(例如重新发布诊断前先清空旧诊断)。
    public mutating func removeAll(where predicate: (Decoration) -> Bool) {
        items.removeAll(where: predicate)
        rebuildMaxEnd()
    }

    /// 追加装饰(O(n) 插入,批量请用 `replaceAll`)。
    public mutating func insert(_ decoration: Decoration) {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            let item = items[mid]
            if item.range.location < decoration.range.location
                || (item.range.location == decoration.range.location && item.id < decoration.id) { low = mid + 1 } else { high = mid }
        }
        items.insert(decoration, at: low)
        rebuildMaxEnd()
    }

    /// 与 `range` 相交的全部装饰(空区间装饰在 `range` 内或边缘时也返回,便于 inlay 命中视口)。
    public func intersecting(_ range: TextSpan) -> [Decoration] {
        guard !items.isEmpty else { return [] }
        // 起点 < range.upperBound 的候选数量(二分)。
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].range.location <= range.upperBound { low = mid + 1 } else { high = mid }
        }
        var result: [Decoration] = []
        var index = low - 1
        // 向前扫描,前缀最大终点 < range.location 时剪枝。
        while index >= 0, maxEnd[index] >= range.location {
            let item = items[index]
            let end = item.range.upperBound
            let hits = item.range.isEmpty
                ? (item.range.location >= range.location && item.range.location <= range.upperBound)
                : (item.range.location < range.upperBound && end > range.location)
            if hits { result.append(item) }
            index -= 1
        }
        result.reverse()
        return result
    }

    /// 覆盖某偏移的装饰(用于悬停命中)。
    public func containing(offset: Int) -> [Decoration] {
        intersecting(TextSpan(location: offset, length: 0)).filter {
            $0.range.isEmpty ? $0.range.location == offset : ($0.range.location <= offset && offset < $0.range.upperBound)
        }
    }

    /// 编辑后平移全部装饰;起点偏向右、终点偏向左(在边缘键入不会被吞进装饰),坍缩的装饰按需移除。
    public mutating func apply(edits: [AppliedEdit]) {
        if edits.isEmpty || items.isEmpty { return }
        var mapped: [Decoration] = []
        mapped.reserveCapacity(items.count)
        for item in items {
            let wasEmpty = item.range.isEmpty
            let start = OffsetMapping.map(item.range.location, through: edits, bias: .right)
            let end = OffsetMapping.map(item.range.upperBound, through: edits, bias: wasEmpty ? .right : .left)
            var next = item
            next.range = TextSpan(lower: start, upper: max(start, end))
            if !wasEmpty, next.range.isEmpty, item.removesWhenCollapsed { continue }
            mapped.append(next)
        }
        items = mapped
        rebuildMaxEnd()
    }

    private mutating func rebuildMaxEnd() {
        maxEnd.removeAll(keepingCapacity: true)
        maxEnd.reserveCapacity(items.count)
        var running = -1
        for item in items {
            running = max(running, item.range.upperBound)
            maxEnd.append(running)
        }
    }
}
