// @author ixxxxoooo
// 用户消息编辑器与外部点击取消测试。

import AppKit
import ChatKit
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("UserMessageEditor")
struct UserMessageEditorTests {
    @Test("StickyUserState 进入与结束编辑状态流转")
    func stickyStateEditingFlow() {
        let state = StickyUserState()
        let entry = TimelineEntry(kind: .user, text: "测试消息")

        #expect(state.editing == nil)
        #expect(!state.editorPinned)

        // 吸顶发起的编辑
        state.beginEditing(entry, pinned: true)
        #expect(state.editing?.id == entry.id)
        #expect(state.editorPinned)
        #expect(state.isEditorFloating(for: entry.id))

        state.finishEditing()
        #expect(state.editing == nil)
        #expect(!state.editorPinned)
        #expect(!state.isEditorFloating(for: entry.id))

        // 就地原位编辑
        state.beginEditing(entry, pinned: false)
        #expect(state.editing?.id == entry.id)
        #expect(!state.editorPinned)
        #expect(!state.isEditorFloating(for: entry.id))

        state.finishEditing()
        #expect(state.editing == nil)
    }

    @Test("点击在编辑卡片内部时放行,点在外部空白处触发取消并消费事件")
    func outsideClickDismiss() {
        let coordinator = OutsideClickDismissCoordinator()
        var dismissed = false
        coordinator.onDismiss = { dismissed = true }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        window.contentView = container

        // 模拟一个位于 (100, 100, 400, 200) 的编辑卡片
        let card = NSView(frame: NSRect(x: 100, y: 100, width: 400, height: 200))
        container.addSubview(card)
        coordinator.box.view = card

        // 1. 点在卡片内部 (200, 200)
        let insideEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 200, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )
        if let insideEvent {
            let consumed = coordinator.handle(insideEvent)
            #expect(!consumed)
            #expect(!dismissed)
        }

        // 2. 点在卡片外部空白处 (50, 50)
        let outsideEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 50, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1.0
        )
        if let outsideEvent {
            let consumed = coordinator.handle(outsideEvent)
            #expect(consumed)
            #expect(dismissed)
        }
    }
}
