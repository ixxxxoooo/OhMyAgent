// @author ixxxxoooo
// 表格列筛选与排序(纯逻辑,无视图):类似 Excel 的「自动筛选」——每列按显示文本勾选保留的值,
// 列的候选值受其他列筛选的影响(级联),首行可作为表头不参与筛选与排序。

import Foundation

/// 排序方向。
public struct SheetSort: Equatable, Sendable {
    public var column: Int
    public var ascending: Bool

    public init(column: Int, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

/// 筛选候选值(列里出现的一个显示文本及其出现次数)。
public struct ColumnValue: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { text }
    /// 显示文本;空串表示「空白」
    public let text: String
    public let count: Int

    public init(text: String, count: Int) {
        self.text = text
        self.count = count
    }
}

/// 一张工作表的筛选/排序状态。
public struct SheetFilterState: Equatable, Sendable {
    /// 列索引 → 允许显示的值集合(没有该键表示该列不筛选)
    public var filters: [Int: Set<String>] = [:]
    /// 当前排序(nil 保持原顺序)
    public var sort: SheetSort?
    /// 首行当作表头:始终显示在最前,不参与筛选与排序
    public var firstRowIsHeader = true

    public init(firstRowIsHeader: Bool = true) { self.firstRowIsHeader = firstRowIsHeader }

    /// 是否有任何生效的筛选或排序。
    public var isActive: Bool { !filters.isEmpty || sort != nil }

    /// 某列是否正在筛选。
    public func isFiltered(column: Int) -> Bool { filters[column] != nil }

    /// 清除全部筛选(保留排序与表头设置)。
    public mutating func clearFilters() { filters = [:] }

    /// 清除某列的筛选。
    public mutating func clearFilter(column: Int) { filters[column] = nil }
}

/// 筛选与排序的计算。
public enum SheetFilter {
    /// 应用筛选与排序,得到要显示的原始行索引(0 起,表头行在最前)。
    /// - Parameters:
    ///   - sheet: 工作表
    ///   - state: 筛选/排序状态
    /// - Returns: 可见行的原始行索引,保持显示顺序
    public static func visibleRows(in sheet: SpreadsheetSheet, state: SheetFilterState) -> [Int] {
        let total = sheet.rows.count
        guard total > 0 else { return [] }
        let headerCount = state.firstRowIsHeader ? 1 : 0
        let body = Array(headerCount..<total).filter { passes(sheet: sheet, row: $0, filters: state.filters) }
        let sorted = state.sort.map { sort(rows: body, in: sheet, by: $0) } ?? body
        return Array(0..<headerCount) + sorted
    }

    /// 某列的候选值(只统计通过「其他列」筛选的行,与 Excel 的级联行为一致)。
    /// - Parameters:
    ///   - sheet: 工作表
    ///   - column: 列索引
    ///   - state: 当前状态
    /// - Returns: 候选值(按显示文本自然排序;空白排在最后)
    public static func distinctValues(in sheet: SpreadsheetSheet, column: Int, state: SheetFilterState) -> [ColumnValue] {
        var others = state.filters
        others[column] = nil
        let start = state.firstRowIsHeader ? 1 : 0
        var counts: [String: Int] = [:]
        if start < sheet.rows.count {
            for row in start..<sheet.rows.count where passes(sheet: sheet, row: row, filters: others) {
                counts[sheet.cell(row: row, column: column).text, default: 0] += 1
            }
        }
        return counts
            .map { ColumnValue(text: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.text.isEmpty != rhs.text.isEmpty { return !lhs.text.isEmpty }
                return compare(lhs.text, rhs.text) == .orderedAscending
            }
    }

    /// 切换某列的一个值(从「全部显示」状态点掉一个值 = 取消勾选它)。
    /// - Parameters:
    ///   - value: 值
    ///   - column: 列
    ///   - available: 该列全部候选值
    ///   - state: 状态(就地修改)
    public static func toggle(_ value: String, column: Int, available: [ColumnValue], in state: inout SheetFilterState) {
        var allowed = state.filters[column] ?? Set(available.map(\.text))
        if allowed.contains(value) { allowed.remove(value) } else { allowed.insert(value) }
        // 全部勾选等价于不筛选
        state.filters[column] = allowed.count == available.count && Set(available.map(\.text)).isSubset(of: allowed) ? nil : allowed
    }

    /// 设置某列允许的值集合(为全集时视为不筛选)。
    public static func setAllowed(_ values: Set<String>, column: Int, available: [ColumnValue], in state: inout SheetFilterState) {
        let all = Set(available.map(\.text))
        state.filters[column] = all.isSubset(of: values) ? nil : values
    }

    // MARK: 内部

    private static func passes(sheet: SpreadsheetSheet, row: Int, filters: [Int: Set<String>]) -> Bool {
        for (column, allowed) in filters where !allowed.contains(sheet.cell(row: row, column: column).text) { return false }
        return true
    }

    private static func sort(rows: [Int], in sheet: SpreadsheetSheet, by sort: SheetSort) -> [Int] {
        // 稳定排序:相等时保持原行序,空白始终排在最后(与 Excel 一致)
        rows.enumerated().sorted { lhs, rhs in
            let a = sheet.cell(row: lhs.element, column: sort.column).text
            let b = sheet.cell(row: rhs.element, column: sort.column).text
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            let order = compare(a, b)
            if order == .orderedSame { return lhs.offset < rhs.offset }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.element)
    }

    /// 比较两个显示文本:都是数字时按数值,否则按自然顺序(中文按拼音)。
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let a = number(lhs), let b = number(rhs), a != b { return a < b ? .orderedAscending : .orderedDescending }
        return lhs.localizedStandardCompare(rhs)
    }

    /// 解析显示文本里的数字(忽略千分位、货币符号、百分号)。
    static func number(_ text: String) -> Double? {
        let cleaned = text.filter { !",%¥$€£ ".contains($0) }
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }
}
