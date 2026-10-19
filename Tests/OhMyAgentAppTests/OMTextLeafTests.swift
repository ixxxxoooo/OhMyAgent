// @author ixxxxoooo
// 文本叶子基础设施:内容签名去重、追加型更新只替换尾部、测量缓存、复制语义、单击回调。

import AppKit
import DesignSystem
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("文本叶子基础设施", .serialized)
struct OMTextLeafTests {
    /// 造一个纯文本富文本(统一属性,便于比较)。
    private func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
    }

    @Test("签名不变时不改动文本存储")
    func sameSignatureIsNoOp() {
        let host = OMLeafHostView(wrap: true)
        let coordinator = OMTextLeafCoordinator()
        coordinator.apply(to: host.textView, signature: 1) { plain("你好") }
        let before = coordinator.edits
        var built = false
        coordinator.apply(to: host.textView, signature: 1) { built = true; return plain("你好") }
        #expect(coordinator.edits == before)
        #expect(!built, "签名没变时不应构建富文本")
    }

    @Test("长文本追加:只替换尾部,结果与整段重建一致")
    func appendReplacesOnlyTheTail() {
        let host = OMLeafHostView(wrap: true)
        let coordinator = OMTextLeafCoordinator()
        var text = String(repeating: "let value = compute(1)\n", count: 200)
        coordinator.apply(to: host.textView, signature: 1) { plain(text) }
        #expect(coordinator.fullRebuilds == 1)
        for step in 2...6 {
            text += "let extra\(step) = 1\n"
            coordinator.apply(to: host.textView, signature: step) { plain(text) }
            guard let storage = host.textView.textStorage else { Issue.record("没有文本存储"); return }
            #expect(storage.isEqual(to: NSTextStorage(attributedString: plain(text))))
        }
        #expect(coordinator.incrementalUpdates == 5)
        #expect(coordinator.fullRebuilds == 1)
    }

    @Test("非追加改写走整体重建")
    func rewriteFallsBackToFullRebuild() {
        let host = OMLeafHostView(wrap: true)
        let coordinator = OMTextLeafCoordinator()
        let base = String(repeating: "abc\n", count: 800)
        coordinator.apply(to: host.textView, signature: 1) { plain(base) }
        coordinator.apply(to: host.textView, signature: 2) { plain("X" + base.dropFirst() + "tail") }
        #expect(coordinator.fullRebuilds == 2)
        #expect(host.textView.string == "X" + base.dropFirst() + "tail")
    }

    @Test("同一宽度与内容的测量只做一次,宽度变化才重新测量")
    func measurementIsCached() {
        let host = OMLeafHostView(wrap: true)
        let coordinator = OMTextLeafCoordinator()
        let config = OMTextLeafConfig()
        coordinator.apply(to: host.textView, signature: 1) { plain(String(repeating: "很长的一行文字 ", count: 40)) }
        let narrow = coordinator.measuredSize(host, config: config, proposedWidth: 200)
        _ = coordinator.measuredSize(host, config: config, proposedWidth: 200)
        #expect(coordinator.measurePasses == 1)
        let wide = coordinator.measuredSize(host, config: config, proposedWidth: 800)
        #expect(coordinator.measurePasses == 2)
        #expect(wide.height < narrow.height, "更宽时折行更少,高度应更小")
    }

    @Test("不折行时内容宽度由最长行决定,宿主宽度等于建议宽度")
    func noWrapUsesLongestLine() {
        let host = OMLeafHostView(wrap: false)
        let coordinator = OMTextLeafCoordinator()
        var config = OMTextLeafConfig()
        config.wrap = false
        coordinator.apply(to: host.textView, signature: 1) { plain(String(repeating: "x", count: 500)) }
        let size = coordinator.measuredSize(host, config: config, proposedWidth: 300)
        #expect(size.width == 300)
        #expect(host.contentSize.width > 300)
        #expect(host.scrollView != nil)
    }

    @Test("复制变换作用于选中文本")
    func copyTransformApplies() {
        let host = OMLeafHostView(wrap: true)
        host.textView.textStorage?.setAttributedString(plain("甲\u{2028}乙"))
        host.textView.copyTransform = { $0.replacingOccurrences(of: "\u{2028}", with: "\n") }
        host.textView.setSelectedRange(NSRange(location: 0, length: 3))
        host.textView.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "甲\n乙")
    }

    @Test("叶子创建后只读、可选,背景透明")
    func leafIsReadOnlySelectable() {
        let view = OMReadOnlyTextView.make(OMReadOnlyTextView.self, layout: OMLeafLayoutManager())
        #expect(!view.isEditable)
        #expect(view.isSelectable)
        #expect(!view.drawsBackground)
        #expect(view.retainedStorage != nil)
    }
}
