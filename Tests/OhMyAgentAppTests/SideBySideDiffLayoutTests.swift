// @author ixxxxoooo
// 并排 Diff 回归:左右两侧等宽;某一侧有比视图更宽的长行时,正文不得左移压住行号槽(文本容器原点保持为 0)。

import AppKit
import DiffKit
import SwiftUI
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("并排 Diff 布局")
struct SideBySideDiffLayoutTests {
    /// 离屏布局并收集所有只读文本视图。
    private func textViews(old: String, new: String) -> [NSTextView] {
        let view = SideBySideDiffView(diff: LineDiff.diff(old: old, new: new)).frame(width: 900)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 10)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: max(host.fittingSize.height, 120))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var found: [NSTextView] = []
        func walk(_ view: NSView) {
            if let text = view as? NSTextView { found.append(text) }
            view.subviews.forEach(walk)
        }
        walk(host)
        return found
    }

    @Test("一侧有超宽长行时,两侧文本容器原点都为 0,且左右视图宽度相等")
    func longLineKeepsOriginAndEqualWidth() {
        let long = String(repeating: "很长的一行", count: 40)
        let views = textViews(old: "a\nb\nc\n", new: "a\n\(long)\nc\n")
        #expect(views.count == 2)
        #expect(views.allSatisfy { $0.textContainerOrigin.x == 0 })
        let scrolls = views.compactMap { $0.enclosingScrollView?.frame.width }
        #expect(scrolls.count == 2 && abs(scrolls[0] - scrolls[1]) <= 1)
    }
}
