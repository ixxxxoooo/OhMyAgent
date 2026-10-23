// @author ixxxxoooo
// 表格内容搜索:在给定行范围内按行优先顺序找出包含关键词的单元格(xlsx 与 CSV 预览共用)。

import Foundation

/// 一处匹配的单元格位置(行、列都从 0 起;行为数据源里的原始行索引)。
public struct TableMatch: Hashable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// 表格搜索。
public enum TableSearch {
    /// 最多返回的匹配数(再多的结果没有浏览意义,也避免巨表占用内存)。
    public static let maxMatches = 20_000

    /// 在指定行里查找包含关键词的单元格(忽略大小写与变音符号)。
    /// - Parameters:
    ///   - query: 关键词;首尾空白会被忽略,为空返回空数组
    ///   - rows: 要搜索的原始行索引(按显示顺序,如筛选排序后的可见行)
    ///   - columnCount: 列数
    ///   - text: 取单元格显示文本的闭包 `(行, 列) -> 文本`
    /// - Returns: 按 `rows` 顺序、行内按列顺序排列的匹配,最多 `maxMatches` 条
    public static func matches(query: String, rows: [Int], columnCount: Int, text: (_ row: Int, _ column: Int) -> String) -> [TableMatch] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, columnCount > 0 else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var result: [TableMatch] = []
        for row in rows {
            for column in 0..<columnCount {
                let cell = text(row, column)
                if !cell.isEmpty, cell.range(of: key, options: options) != nil {
                    result.append(TableMatch(row: row, column: column))
                    if result.count >= maxMatches { return result }
                }
            }
        }
        return result
    }
}
