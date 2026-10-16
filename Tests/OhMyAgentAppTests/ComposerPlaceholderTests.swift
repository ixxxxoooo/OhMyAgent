// @author ixxxxoooo
// 输入框占位文字:输入法组合(拼音还未上屏)期间必须隐藏,否则与拼音字母重叠;悬浮窗几何计算。

import AppKit
import Foundation
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("输入框占位文字与输入法组合")
struct ComposerPlaceholderTests {
    private func makeView() -> SubmitTextView {
        let view = SubmitTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        view.placeholder = "向 Agent 提问"
        view.layoutSubtreeIfNeeded()
        view.refreshPlaceholder()
        return view
    }

    @Test("空输入显示占位;输入文字后隐藏")
    func plainTyping() {
        let view = makeView()
        #expect(view.isPlaceholderVisible)
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.isPlaceholderVisible)
        view.string = ""
        view.didChangeText()
        #expect(view.isPlaceholderVisible)
    }

    @Test("输入法组合文本(拼音 fen)出现时立即隐藏占位,取消组合后恢复")
    func markedText() {
        let view = makeView()
        view.setMarkedText("fen", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(!view.isPlaceholderVisible)
        // 候选上屏
        view.insertText("分", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        #expect(!view.isPlaceholderVisible)
        // 再次组合后删除干净
        view.string = ""
        view.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.isPlaceholderVisible)
        view.unmarkText()
        view.string = ""
        view.didChangeText()
        #expect(view.isPlaceholderVisible)
    }
}

@Suite("悬浮窗几何")
struct FloatingPanelGeometryTests {
    private let container = CGSize(width: 1000, height: 700)

    @Test("首次打开居中且在容器内")
    func initial() {
        let frame = FloatingPanelGeometry.initialFrame(in: container)
        #expect(abs(frame.midX - 500) < 0.5 && abs(frame.midY - 350) < 0.5)
        #expect(CGRect(origin: .zero, size: container).contains(frame))
    }

    @Test("移动时标题栏始终留在容器内")
    func move() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 400)
        let far = FloatingPanelGeometry.moved(frame, by: CGSize(width: 5000, height: 5000), in: container, headerHeight: 36)
        #expect(far.minX <= container.width - 80)
        #expect(far.minY <= container.height - 36)
        let up = FloatingPanelGeometry.moved(frame, by: CGSize(width: 0, height: -5000), in: container, headerHeight: 36)
        #expect(up.minY == 0)
    }

    @Test("缩放不小于最小尺寸,左上角手柄固定对边")
    func resize() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 400)
        let shrunk = FloatingPanelGeometry.resized(frame, handle: .bottomTrailing, by: CGSize(width: -900, height: -900), in: container)
        #expect(shrunk.size == FloatingPanelGeometry.minSize)
        #expect(shrunk.origin == frame.origin)
        let fromTopLeft = FloatingPanelGeometry.resized(frame, handle: .topLeading, by: CGSize(width: 900, height: 900), in: container)
        #expect(fromTopLeft.maxX == frame.maxX && fromTopLeft.maxY == frame.maxY)
        #expect(fromTopLeft.size == FloatingPanelGeometry.minSize)
        let grown = FloatingPanelGeometry.resized(frame, handle: .trailing, by: CGSize(width: 9000, height: 0), in: container)
        #expect(grown.maxX == container.width)
    }
}
