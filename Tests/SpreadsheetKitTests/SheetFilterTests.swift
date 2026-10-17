// @author ixxxxoooo
// 表格列筛选与排序测试。

import Testing
@testable import SpreadsheetKit

@Suite("SheetFilter")
struct SheetFilterTests {
    /// 表头 + 5 行:姓名 / 部门 / 金额
    private func sample() -> SpreadsheetSheet {
        func row(_ a: String, _ b: String, _ c: String) -> [SpreadsheetCell] {
            [SpreadsheetCell(text: a), SpreadsheetCell(text: b), SpreadsheetCell(text: c, kind: .number)]
        }
        return SpreadsheetSheet(name: "S", rows: [
            row("姓名", "部门", "金额"),
            row("张三", "研发", "1,200"),
            row("李四", "市场", "300"),
            row("王五", "研发", "45"),
            row("赵六", "", "9,000"),
            row("钱七", "市场", ""),
        ], columnCount: 3)
    }

    @Test("没有筛选时全部可见,表头在最前")
    func noFilter() {
        #expect(SheetFilter.visibleRows(in: sample(), state: SheetFilterState()) == [0, 1, 2, 3, 4, 5])
    }

    @Test("按列勾选保留的值,表头行不参与筛选")
    func filterByColumn() {
        var state = SheetFilterState()
        state.filters[1] = ["研发"]
        #expect(SheetFilter.visibleRows(in: sample(), state: state) == [0, 1, 3])
    }

    @Test("多列筛选取交集")
    func multipleColumns() {
        var state = SheetFilterState()
        state.filters[1] = ["研发", "市场"]
        state.filters[0] = ["李四", "王五"]
        #expect(SheetFilter.visibleRows(in: sample(), state: state) == [0, 2, 3])
    }

    @Test("候选值级联:统计只受其他列筛选影响,空白排最后")
    func cascadingValues() {
        var state = SheetFilterState()
        let all = SheetFilter.distinctValues(in: sample(), column: 1, state: state)
        #expect(all.map(\.text) == ["市场", "研发", ""])
        #expect(all.first { $0.text == "研发" }?.count == 2)
        // 只看金额大于 100 的行之外的其他列筛选:姓名限制为张三 → 部门只剩研发
        state.filters[0] = ["张三"]
        #expect(SheetFilter.distinctValues(in: sample(), column: 1, state: state).map(\.text) == ["研发"])
        // 本列自己的筛选不影响自己的候选值
        state.filters[1] = ["研发"]
        state.filters[0] = nil
        #expect(SheetFilter.distinctValues(in: sample(), column: 1, state: state).count == 3)
    }

    @Test("数字列按数值排序(忽略千分位),空白始终在最后")
    func numericSort() {
        var state = SheetFilterState()
        state.sort = SheetSort(column: 2, ascending: true)
        #expect(SheetFilter.visibleRows(in: sample(), state: state) == [0, 3, 2, 1, 4, 5])
        state.sort = SheetSort(column: 2, ascending: false)
        #expect(SheetFilter.visibleRows(in: sample(), state: state) == [0, 4, 1, 2, 3, 5])
    }

    @Test("相等值保持原顺序(稳定排序)")
    func stableSort() {
        var state = SheetFilterState()
        state.sort = SheetSort(column: 1, ascending: true)
        let rows = SheetFilter.visibleRows(in: sample(), state: state)
        // 研发:行 1 在行 3 之前;市场:行 2 在行 5 之前
        #expect(rows.firstIndex(of: 1)! < rows.firstIndex(of: 3)!)
        #expect(rows.firstIndex(of: 2)! < rows.firstIndex(of: 5)!)
    }

    @Test("首行不当表头时参与筛选")
    func noHeader() {
        var state = SheetFilterState()
        state.firstRowIsHeader = false
        state.filters[1] = ["部门"]
        #expect(SheetFilter.visibleRows(in: sample(), state: state) == [0])
    }

    @Test("勾选全部等价于不筛选;逐个取消勾选形成筛选")
    func toggleSemantics() {
        var state = SheetFilterState()
        let values = SheetFilter.distinctValues(in: sample(), column: 1, state: state)
        SheetFilter.toggle("研发", column: 1, available: values, in: &state)
        #expect(state.filters[1] == ["市场", ""])
        SheetFilter.toggle("研发", column: 1, available: values, in: &state)
        #expect(state.filters[1] == nil)
        SheetFilter.setAllowed(["市场"], column: 1, available: values, in: &state)
        #expect(state.isFiltered(column: 1))
        SheetFilter.setAllowed(Set(values.map(\.text)), column: 1, available: values, in: &state)
        #expect(!state.isFiltered(column: 1))
    }
}
