// @author ixxxxoooo
// 表格内容搜索测试。

import Testing
@testable import SpreadsheetKit

@Suite("TableSearch")
struct TableSearchTests {
    private let grid = [
        ["姓名", "部门", "备注"],
        ["张三", "研发", "Alpha"],
        ["李四", "市场", "alphabet"],
        ["王五", "研发", ""],
    ]

    private func find(_ query: String, rows: [Int]? = nil) -> [TableMatch] {
        TableSearch.matches(query: query, rows: rows ?? Array(grid.indices), columnCount: 3) { row, column in
            grid[row][column]
        }
    }

    @Test("忽略大小写,按行优先顺序返回")
    func caseInsensitiveRowMajor() {
        #expect(find("alpha") == [TableMatch(row: 1, column: 2), TableMatch(row: 2, column: 2)])
        #expect(find("研发") == [TableMatch(row: 1, column: 1), TableMatch(row: 3, column: 1)])
    }

    @Test("空关键词与纯空白没有结果")
    func emptyQuery() {
        #expect(find("").isEmpty)
        #expect(find("   ").isEmpty)
    }

    @Test("只在给定行里搜索,并保持给定顺序(筛选/排序后的可见行)")
    func restrictedRows() {
        #expect(find("研发", rows: [3, 0]) == [TableMatch(row: 3, column: 1)])
        #expect(find("a", rows: [2, 1]).map(\.row) == [2, 1])
    }

    @Test("没有命中返回空数组")
    func noHit() {
        #expect(find("不存在").isEmpty)
    }
}
