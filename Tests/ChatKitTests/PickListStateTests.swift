// @author ixxxxoooo
// 选择列表逻辑:搜索过滤/排序、↑↓ 循环与跳过禁用项、回车确认、初始高亮落在已选项。

import Testing
@testable import ChatKit

@Suite("选择列表状态")
struct PickListStateTests {
    private struct Row: PickListItem {
        var id: String
        var searchText: String
        var group: String?
        var isEnabled = true
    }

    private func rows() -> [Row] {
        [
            Row(id: "a", searchText: "main 主分支"),
            Row(id: "b", searchText: "feature/login"),
            Row(id: "c", searchText: "feature/logout", isEnabled: false),
            Row(id: "d", searchText: "release-1.0"),
        ]
    }

    @Test("初始高亮优先落在已选项,否则第一个可用项")
    func initialHighlight() {
        #expect(PickListState(items: rows(), selectedID: "d").highlightedID == "d")
        #expect(PickListState(items: rows()).highlightedID == "a")
        // 已选项被禁用时回退到第一个可用项
        #expect(PickListState(items: rows(), selectedID: "c").highlightedID == "a")
    }

    @Test("↑↓ 循环移动并跳过禁用项")
    func moveWrapsAndSkipsDisabled() {
        var state = PickListState(items: rows())
        state.move(1); #expect(state.highlightedID == "b")
        state.move(1); #expect(state.highlightedID == "d")   // 跳过禁用的 c
        state.move(1); #expect(state.highlightedID == "a")   // 向下循环
        state.move(-1); #expect(state.highlightedID == "d")  // 向上循环
    }

    @Test("搜索过滤:多词都需命中,前缀优先于子串,修改查询后高亮回到第一项")
    func filterAndRank() {
        var state = PickListState(items: rows(), selectedID: "d")
        state.query = "feat log"
        #expect(state.visible.map(\.id) == ["b", "c"])
        #expect(state.highlightedID == "b")
        state.query = "1.0"
        #expect(state.visible.map(\.id) == ["d"])
        state.query = "zzz"
        #expect(state.visible.isEmpty && state.highlighted == nil)
        state.move(1)
        #expect(state.highlightedID == nil)
    }

    @Test("前缀匹配排在子串匹配之前,子序列模糊匹配兜底")
    func rankingOrder() {
        let items = [Row(id: "x", searchText: "my-main"), Row(id: "y", searchText: "main")]
        var state = PickListState(items: items)
        state.query = "main"
        #expect(state.visible.map(\.id) == ["y", "x"])
        state.query = "mn"  // 子序列
        #expect(Set(state.visible.map(\.id)) == ["x", "y"])
    }

    @Test("回车确认取当前高亮;悬停高亮忽略禁用项")
    func confirmAndHover() {
        var state = PickListState(items: rows())
        state.highlight("c")
        #expect(state.highlightedID == "a")
        state.highlight("d")
        #expect(state.highlighted?.id == "d")
    }

    @Test("替换条目保留查询词,高亮项消失时回到第一项")
    func setItemsKeepsQuery() {
        var state = PickListState(items: rows())
        state.query = "feature"
        state.move(1)
        state.setItems([Row(id: "z", searchText: "feature/new")])
        #expect(state.query == "feature" && state.highlightedID == "z")
    }
}
