// @author ixxxxoooo
// 右键菜单模型:规整、键盘导航、子菜单展开与激活。

import Testing
@testable import ChatKit

@MainActor
@Suite("右键菜单模型")
struct ContextMenuModelTests {
    private func item(_ title: String, enabled: Bool = true, action: (@MainActor () -> Void)? = nil) -> MenuEntry {
        MenuEntry(title: title, isEnabled: enabled, action: action)
    }

    private var divider: MenuEntry { MenuEntry(kind: .divider) }

    @Test("规整:去掉首尾与连续分隔线,按路径赋 ID")
    func normalize() {
        let entries = MenuEntry.normalized([divider, item("a"), divider, divider, item("b"), divider])
        #expect(entries.map(\.title) == ["a", "", "b"])
        #expect(entries.map(\.id) == ["0", "1", "2"])
    }

    @Test("↑↓ 跳过分隔线与禁用项,到头不循环")
    func moveSkipsUnselectable() {
        var state = ContextMenuState(entries: [item("a"), divider, item("b", enabled: false), item("c")])
        state.move(1)
        #expect(state.highlightedID == "0")
        state.move(1)
        #expect(state.highlightedID == "3")
        state.move(1)
        #expect(state.highlightedID == "3")
        state.move(-1)
        #expect(state.highlightedID == "0")
        state.move(-1)
        #expect(state.highlightedID == "0")
    }

    @Test("回车执行动作;禁用项与分隔线无动作")
    func activateRuns() {
        var ran = 0
        var state = ContextMenuState(entries: [item("a", action: { ran += 1 }), item("b", enabled: false, action: { ran += 10 })])
        guard case .run(let action) = state.activate("0") else { Issue.record("应执行"); return }
        action()
        #expect(ran == 1)
        if case .none = state.activate("1") {} else { Issue.record("禁用项不应执行") }
    }

    @Test("子菜单:回车展开、→ 展开并进入首项、← 折叠回父项")
    func submenu() {
        var picked = ""
        let sub = MenuEntry(kind: .submenu([item("会话 ID", action: { picked = "id" }), item("标题", action: { picked = "title" })]), title: "拷贝")
        var state = ContextMenuState(entries: [item("打开"), sub])
        state.highlight("1")
        if case .toggled = state.activate() {} else { Issue.record("应展开") }
        #expect(state.rows.map(\.depth) == [0, 0, 1, 1])
        state.move(1)
        #expect(state.highlightedID == "1.0")
        state.collapseHighlighted()
        #expect(state.highlightedID == "1")
        #expect(state.rows.count == 2)
        state.expandHighlighted()
        #expect(state.highlightedID == "1.0")
        guard case .run(let action) = state.activate() else { Issue.record("应执行子项"); return }
        action()
        #expect(picked == "id")
    }
}
