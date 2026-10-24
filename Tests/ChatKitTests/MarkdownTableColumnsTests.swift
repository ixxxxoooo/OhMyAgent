// @author ixxxxoooo
// Markdown 表格列数:以表头为准(GFM)。数据行多出的单元格被忽略,不能让整张表多出一列空白列。

import Foundation
import Testing
@testable import ChatKit

@Suite("Markdown 表格列数")
struct MarkdownTableColumnsTests {
    private func table(_ text: String) -> (header: [String], rows: [[String]])? {
        for block in MarkdownParser.parse(text) {
            if case .table(let header, let rows, _) = block { return (header, rows) }
        }
        return nil
    }

    @Test("数据行单元格比表头多:多出的被忽略(行内代码里没转义的竖线是常见成因)")
    func extraCellsAreDropped() throws {
        let result = try #require(table("| 阶段 | 状态 | 说明 |\n|---|---|---|\n| A | 完成 | 正常 |\n| B | 完成 | `x=right|bottom` 多出的 |\n"))
        #expect(result.header.count == 3)
        #expect(result.rows.allSatisfy { $0.count <= 3 })
        #expect(result.rows[1].count == 3)
    }

    @Test("转义的竖线保留在单元格里,不拆列")
    func escapedPipeStays() throws {
        let result = try #require(table("| 阶段 | 说明 |\n|---|---|\n| A | `x=right\\|bottom` |\n"))
        #expect(result.rows[0].count == 2)
        #expect(result.rows[0][1].contains("right|bottom"))
    }

    @Test("数据行比表头少:保持原样(渲染端补空单元格)")
    func shortRowsAreKept() throws {
        let result = try #require(table("| a | b | c |\n|---|---|---|\n| 1 | 2 |\n"))
        #expect(result.rows[0].count == 2)
    }
}
