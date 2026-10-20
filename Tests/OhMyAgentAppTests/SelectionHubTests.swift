// @author ixxxxoooo
// 跨叶子选择中枢:在离屏窗口里搭一个「滚动视图 + 若干文本叶子」,用与跟踪循环相同的入口
// (beginSelection / extendSelection)驱动选择,检查复制文本、高亮范围、卸载后的冻结、全选与清除。

import AppKit
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("跨叶子选择中枢", .serialized)
struct SelectionHubTests {
    /// 测试场景:一个窗口里的滚动视图,文档视图自上而下排布若干叶子。
    @MainActor
    final class Fixture {
        let window: NSWindow
        let scroll: NSScrollView
        let document: FlippedView
        var leaves: [OMReadOnlyTextView] = []

        /// 文档视图(自上而下坐标,与 SwiftUI 的滚动内容一致)。
        final class FlippedView: NSView {
            override var isFlipped: Bool { true }
        }

        /// - Parameter texts: 每个叶子的文本(单行,等宽字体,每个叶子高 20、间隔 10)
        init(_ texts: [String]) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
            scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            document = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: CGFloat(texts.count) * 30 + 10))
            scroll.documentView = document
            window.contentView = scroll
            for (index, text) in texts.enumerated() {
                let leaf = OMReadOnlyTextView.make(OMReadOnlyTextView.self, layout: OMLeafLayoutManager())
                leaf.textStorage?.setAttributedString(NSAttributedString(
                    string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
                leaf.textContainer?.size = NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)
                leaf.frame = NSRect(x: 10, y: CGFloat(index) * 30 + 10, width: 380, height: 20)
                document.addSubview(leaf)
                leaves.append(leaf)
            }
            SelectionHub.shared.clearSelection()
        }

        /// 叶子内第 `offset` 个字符左边缘处的窗口坐标(y 取该叶子行中部)。
        func windowPoint(leaf index: Int, offset: Int) -> NSPoint {
            let leaf = leaves[index]
            let glyph = leaf.layoutManager?.location(forGlyphAt: min(offset, max(0, (leaf.textStorage?.length ?? 1) - 1))).x ?? 0
            var x = glyph
            // 末尾偏移:取最后一个字符的右边缘
            if offset >= (leaf.textStorage?.length ?? 0), let layout = leaf.layoutManager, let length = leaf.textStorage?.length, length > 0 {
                x = layout.boundingRect(forGlyphRange: NSRange(location: length - 1, length: 1), in: leaf.textContainer ?? NSTextContainer()).maxX
            }
            return leaf.convert(NSPoint(x: x + 0.5, y: 10), to: nil)
        }

        /// 两个叶子之间空隙里的窗口坐标。
        func gapPoint(afterLeaf index: Int) -> NSPoint {
            document.convert(NSPoint(x: 100, y: CGFloat(index) * 30 + 10 + 20 + 5), to: nil)
        }
    }

    @Test("跨三个叶子:起点中段到终点中段,叶子之间空一行")
    func selectAcrossLeaves() {
        let f = Fixture(["第一段文字", "第二段文字", "第三段文字"])
        let hub = SelectionHub.shared
        #expect(hub.beginSelection(at: f.windowPoint(leaf: 0, offset: 2), from: f.leaves[0]))
        hub.extendSelection(to: f.windowPoint(leaf: 2, offset: 3))
        #expect(hub.hasSelection)
        #expect(hub.selectedText() == "段文字\n\n第二段文字\n\n第三段")
        hub.clearSelection()
    }

    @Test("反向拖动(自下而上)得到相同文本")
    func reverseDirection() {
        let f = Fixture(["第一段文字", "第二段文字", "第三段文字"])
        let hub = SelectionHub.shared
        hub.beginSelection(at: f.windowPoint(leaf: 2, offset: 3), from: f.leaves[2])
        hub.extendSelection(to: f.windowPoint(leaf: 0, offset: 2))
        #expect(hub.selectedText() == "段文字\n\n第二段文字\n\n第三段")
        hub.clearSelection()
    }

    @Test("同一叶子内拖选等于子串")
    func insideOneLeaf() {
        let f = Fixture(["abcdefghij", "klm"])
        let hub = SelectionHub.shared
        hub.beginSelection(at: f.windowPoint(leaf: 0, offset: 2), from: f.leaves[0])
        hub.extendSelection(to: f.windowPoint(leaf: 0, offset: 6))
        #expect(hub.selectedText() == "cdef")
        hub.clearSelection()
    }

    @Test("起止点落在叶子之间的空隙:算作下一个叶子的开头,上一个叶子完整保留")
    func gapPoints() {
        let f = Fixture(["甲甲", "乙乙", "丙丙"])
        let hub = SelectionHub.shared
        hub.beginSelection(at: f.windowPoint(leaf: 0, offset: 1), from: f.leaves[0])
        hub.extendSelection(to: f.gapPoint(afterLeaf: 1))
        #expect(hub.selectedText() == "甲\n\n乙乙")
        hub.clearSelection()
    }

    @Test("高亮范围画在叶子上,清除后还原")
    func highlightsAndClear() {
        let f = Fixture(["abcdef", "ghijkl"])
        let hub = SelectionHub.shared
        hub.beginSelection(at: f.windowPoint(leaf: 0, offset: 2), from: f.leaves[0])
        hub.extendSelection(to: f.windowPoint(leaf: 1, offset: 3))
        #expect(f.leaves[0].hubRange == NSRange(location: 2, length: 4))
        #expect(f.leaves[1].hubRange == NSRange(location: 0, length: 3))
        hub.clearSelection()
        #expect(f.leaves[0].hubRange == nil)
        #expect(f.leaves[1].hubRange == nil)
        #expect(!hub.hasSelection)
    }

    @Test("叶子被卸载(滚出视口)后,选中的文本仍可复制")
    func unmountedLeafStaysCopyable() {
        let f = Fixture(["第一段", "第二段", "第三段"])
        let hub = SelectionHub.shared
        hub.beginSelection(at: f.windowPoint(leaf: 0, offset: 0), from: f.leaves[0])
        hub.extendSelection(to: f.windowPoint(leaf: 2, offset: 3))
        f.leaves[1].removeFromSuperview()
        #expect(hub.selectedText() == "第一段\n\n第二段\n\n第三段")
        hub.clearSelection()
    }

    @Test("复制变换作用于每个叶子的文本")
    func copyTransformApplies() {
        let f = Fixture(["甲\u{2028}乙", "丙"])
        f.leaves[0].copyTransform = { $0.replacingOccurrences(of: "\u{2028}", with: "\n") }
        let hub = SelectionHub.shared
        hub.beginSelection(at: f.windowPoint(leaf: 0, offset: 0), from: f.leaves[0])
        hub.extendSelection(to: f.windowPoint(leaf: 1, offset: 1))
        #expect(hub.selectedText() == "甲\n乙\n\n丙")
        hub.clearSelection()
    }

    @Test("全选:选中所有已挂载叶子的全部文本")
    func selectAll() {
        let f = Fixture(["一", "二", "三"])
        let hub = SelectionHub.shared
        hub.selectAll(from: f.leaves[1])
        #expect(hub.selectedText() == "一\n\n二\n\n三")
        hub.clearSelection()
    }

    @Test("复制写入剪贴板")
    func copyToPasteboard() {
        let f = Fixture(["alpha", "beta"])
        let hub = SelectionHub.shared
        hub.beginSelection(at: f.windowPoint(leaf: 0, offset: 0), from: f.leaves[0])
        hub.extendSelection(to: f.windowPoint(leaf: 1, offset: 4))
        NSPasteboard.general.clearContents()
        #expect(hub.copySelection())
        #expect(NSPasteboard.general.string(forType: .string) == "alpha\n\nbeta")
        hub.clearSelection()
    }

    @Test("拖动期间只遍历已挂载的叶子:50 个叶子拖选结果正确")
    func manyLeaves() {
        let texts = (0..<50).map { "行\($0)" }
        let f = Fixture(texts)
        let hub = SelectionHub.shared
        hub.beginSelection(at: f.windowPoint(leaf: 0, offset: 0), from: f.leaves[0])
        hub.extendSelection(to: f.windowPoint(leaf: 49, offset: 3))
        #expect(hub.selectedText() == texts.joined(separator: "\n\n"))
        hub.clearSelection()
    }

    @Test("选择期间上方内容增长导致叶子整体下移:选择不悬空,仍可继续拖选")
    func leavesShiftDuringSelection() {
        let f = Fixture(["第一段文字", "第二段文字", "第三段文字"])
        let hub = SelectionHub.shared
        hub.beginSelection(at: f.windowPoint(leaf: 0, offset: 2), from: f.leaves[0])
        hub.extendSelection(to: f.windowPoint(leaf: 1, offset: 3))
        #expect(hub.selectedText() == "段文字\n\n第二段")
        // 模拟流式输出把下面的叶子整体推下 40pt(键以位置为基础,会整体改变)
        f.document.frame.size.height += 40
        for leaf in f.leaves.dropFirst() { leaf.frame.origin.y += 40 }
        hub.extendSelection(to: f.windowPoint(leaf: 2, offset: 3))
        #expect(hub.hasSelection)
        #expect(hub.selectedText() == "段文字\n\n第二段文字\n\n第三段")
        hub.clearSelection()
    }

    @Test("叶子内容被重建后高亮自动补画")
    func highlightReplayedAfterContentChange() {
        let f = Fixture(["abcdefghij", "klm"])
        let hub = SelectionHub.shared
        hub.beginSelection(at: f.windowPoint(leaf: 0, offset: 2), from: f.leaves[0])
        hub.extendSelection(to: f.windowPoint(leaf: 0, offset: 6))
        let leaf = f.leaves[0]
        #expect(leaf.hubRange != nil)
        // 内容被重建(模拟流式更新):临时属性随之丢失,hubRange 缓存若不重置就不会再画
        leaf.textStorage?.setAttributedString(NSAttributedString(
            string: "abcdefghij", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
        hub.leafContentDidChange(leaf)
        let attribute = leaf.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 3, effectiveRange: nil)
        #expect(attribute != nil, "重建后选区高亮应被补画")
        hub.clearSelection()
    }

    @Test("没有叶子/没有选择时复制返回 false")
    func noSelection() {
        SelectionHub.shared.clearSelection()
        #expect(!SelectionHub.shared.hasSelection)
        #expect(!SelectionHub.shared.copySelection())
    }
}
