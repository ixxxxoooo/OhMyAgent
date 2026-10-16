// @author ixxxxoooo
// 标签快捷操作:关闭栈(⌘⇧T)、⌘1–9 下标、⌃Tab 循环。

import ChatKit
import Foundation
import Testing

@testable import WorkbenchKit

@Suite("标签快捷操作")
struct TabShortcutsTests {
    private func tab(_ path: String) -> WorkbenchTab {
        WorkbenchTab(kind: .file(path: path), title: (path as NSString).lastPathComponent, line: 7)
    }

    @Test("关闭栈后进先出,同一内容只保留最近一次")
    func stackOrderAndDedupe() {
        var stack = ClosedTabStack()
        stack.push(tab("/a.swift"))
        stack.push(tab("/b.swift"))
        stack.push(tab("/a.swift"))
        #expect(stack.items.count == 2)
        #expect(stack.pop()?.kind == .file(path: "/a.swift"))
        #expect(stack.pop()?.kind == .file(path: "/b.swift"))
        #expect(stack.pop() == nil)
    }

    @Test("终端与预览不进入关闭栈;容量有上限")
    func stackFilterAndCapacity() {
        var stack = ClosedTabStack(capacity: 3)
        stack.push(WorkbenchTab(kind: .terminal(id: "t"), title: "终端"))
        stack.push(WorkbenchTab(kind: .preview(id: "p"), title: "预览"))
        #expect(stack.items.isEmpty)
        for name in ["a", "b", "c", "d"] { stack.push(tab("/\(name)")) }
        #expect(stack.items.map(\.title) == ["b", "c", "d"])
        #expect(stack.items.first?.line == 7)
    }

    @Test("⌘1–9:⌘9 固定为最后一个,越界为 nil")
    func shortcutIndex() {
        #expect(TabNavigation.index(forShortcut: 1, count: 5) == 0)
        #expect(TabNavigation.index(forShortcut: 5, count: 5) == 4)
        #expect(TabNavigation.index(forShortcut: 6, count: 5) == nil)
        #expect(TabNavigation.index(forShortcut: 9, count: 5) == 4)
        #expect(TabNavigation.index(forShortcut: 9, count: 12) == 11)
        #expect(TabNavigation.index(forShortcut: 0, count: 3) == nil)
        #expect(TabNavigation.index(forShortcut: 1, count: 0) == nil)
    }

    @Test("⌃Tab 首尾循环")
    func cycle() {
        #expect(TabNavigation.cycled(from: 2, delta: 1, count: 3) == 0)
        #expect(TabNavigation.cycled(from: 0, delta: -1, count: 3) == 2)
        #expect(TabNavigation.cycled(from: 1, delta: 1, count: 3) == 2)
        #expect(TabNavigation.cycled(from: 0, delta: 1, count: 0) == nil)
    }

    @MainActor
    @Test("模型:关闭后可 ⌘⇧T 恢复,并跳过已移除项目的会话")
    func modelReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkbenchStore(fileURL: dir.appendingPathComponent("state/workbench.json"))
        let model = WorkbenchModel(store: store, autoConnect: false) { url in
            let session = SessionModel(workspace: url)
            session.attention = AttentionCenter()
            return session
        }
        let id = model.openFile("/tmp/x.swift", preview: false)
        model.closeTab(id)
        #expect(model.dock.allTabs.contains { $0.kind == .file(path: "/tmp/x.swift") } == false)
        #expect(model.reopenClosedTab())
        #expect(model.dock.allTabs.contains { $0.kind == .file(path: "/tmp/x.swift") })
        #expect(!model.reopenClosedTab())
    }
}
