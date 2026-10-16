// @author ixxxxoooo
// 选择列表的纯逻辑:搜索过滤与排序、↑↓ 高亮移动(循环、跳过禁用项)、回车确认。
// 视图层(`OMPickList`)只负责渲染与按键转发,所有行为在这里可单测。

import Foundation

/// 选择列表的一项。
public protocol PickListItem: Identifiable, Sendable where ID == String {
    /// 参与搜索的文本(标题、副标题、别名拼在一起,大小写不敏感)
    var searchText: String { get }
    /// 分组标题;相邻项分组相同则归为一组,nil 表示不分组
    var group: String? { get }
    /// 是否可选(禁用项可见但不可高亮/确认)
    var isEnabled: Bool { get }
}

extension PickListItem {
    public var group: String? { nil }
    public var isEnabled: Bool { true }
}

/// 搜索匹配与打分。
public enum PickListMatcher {
    /// 计算查询词对文本的匹配分(越小越靠前);不匹配返回 nil。
    ///
    /// 规则:查询按空白拆成多个词,每个词都必须命中;词出现在文本开头得分最好,
    /// 其次为词首(单词边界),再次为任意子串,最后允许按顺序的子序列模糊匹配。
    /// - Parameters:
    ///   - query: 查询词(可含多个以空白分隔的词)
    ///   - text: 待匹配文本
    /// - Returns: 总分;空查询返回 0
    public static func score(query: String, in text: String) -> Int? {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return 0 }
        let haystack = text.lowercased()
        var total = 0
        for token in tokens {
            guard let value = tokenScore(token, in: haystack) else { return nil }
            total += value
        }
        return total
    }

    private static func tokenScore(_ token: String, in haystack: String) -> Int? {
        if haystack.hasPrefix(token) { return 0 }
        if let range = haystack.range(of: token) {
            let index = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let previous = haystack[haystack.index(haystack.startIndex, offsetBy: index - 1)]
            let boundary = !(previous.isLetter || previous.isNumber)
            return boundary ? 10 + index : 100 + index
        }
        // 子序列:token 的字符按顺序出现在文本里
        var cursor = haystack.startIndex
        for character in token {
            guard let found = haystack[cursor...].firstIndex(of: character) else { return nil }
            cursor = haystack.index(after: found)
        }
        return 1000
    }
}

/// 选择列表状态:条目、查询词、可见条目与高亮项。
public struct PickListState<Item: PickListItem>: Sendable {
    /// 全部条目
    public private(set) var items: [Item]
    /// 查询词;修改后重新过滤并把高亮移到第一项
    public var query: String { didSet { if query != oldValue { refresh(keepHighlight: false) } } }
    /// 当前已选中(打勾)的条目 ID
    public let selectedID: String?
    /// 过滤并排序后的可见条目
    public private(set) var visible: [Item] = []
    /// 当前高亮项 ID
    public private(set) var highlightedID: String?

    /// - Parameters:
    ///   - items: 全部条目
    ///   - selectedID: 已选中项 ID;首次高亮优先落在它上面
    ///   - query: 初始查询词
    public init(items: [Item], selectedID: String? = nil, query: String = "") {
        self.items = items
        self.selectedID = selectedID
        self.query = query
        refresh(keepHighlight: false)
    }

    /// 替换条目(保留查询词与高亮,高亮项不存在时回到第一项)。
    public mutating func setItems(_ newItems: [Item]) {
        items = newItems
        refresh(keepHighlight: true)
    }

    /// 移动高亮:`step > 0` 向下,`< 0` 向上;循环、跳过禁用项;无可选项时不变。
    /// - Parameter step: 步数(通常为 ±1)
    public mutating func move(_ step: Int) {
        let enabled = visible.filter(\.isEnabled)
        guard !enabled.isEmpty, step != 0 else { return }
        guard let current = highlightedID, let index = enabled.firstIndex(where: { $0.id == current }) else {
            highlightedID = (step > 0 ? enabled.first : enabled.last)?.id
            return
        }
        let count = enabled.count
        let next = ((index + step) % count + count) % count
        highlightedID = enabled[next].id
    }

    /// 直接高亮某项(鼠标悬停);禁用项或不可见项忽略。
    public mutating func highlight(_ id: String) {
        guard visible.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        highlightedID = id
    }

    /// 当前高亮的条目(回车确认的对象)。
    public var highlighted: Item? {
        guard let highlightedID else { return nil }
        return visible.first { $0.id == highlightedID && $0.isEnabled }
    }

    private mutating func refresh(keepHighlight: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            visible = items
        } else {
            let scored: [(offset: Int, item: Item, score: Int)] = items.enumerated().compactMap { offset, item in
                PickListMatcher.score(query: trimmed, in: item.searchText).map { (offset, item, $0) }
            }
            visible = scored.sorted { ($0.score, $0.offset) < ($1.score, $1.offset) }.map(\.item)
        }
        if keepHighlight, let id = highlightedID, visible.contains(where: { $0.id == id && $0.isEnabled }) { return }
        if trimmed.isEmpty, let selectedID, visible.contains(where: { $0.id == selectedID && $0.isEnabled }) {
            highlightedID = selectedID
        } else {
            highlightedID = visible.first(where: \.isEnabled)?.id
        }
    }
}
