// @author ixxxxoooo
// Markdown 文字段的测量缓存与外观应用:同宽二次测量不重排;nil/0 提议不改容器宽度;颜色没变不重设属性与重绘。

import AppKit
import ChatKit
import DesignSystem
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("Markdown 文字段测量与外观", .serialized)
struct MarkdownTextRunMeasureTests {
    private let blocks: [MarkdownBlock] = [.paragraph(String(repeating: "这是一段用于测量排版高度的较长文字,", count: 12)), .paragraph("第二段")]

    private func makeRendered() -> (renderer: MarkdownTextRunRenderer, view: MarkdownTextView) {
        let renderer = MarkdownTextRunRenderer()
        let view = MarkdownTextRepresentable.makeTextView()
        renderer.apply(blocks, to: view)
        return (renderer, view)
    }

    @Test("同宽二次测量命中缓存,不重新排版")
    func sameWidthMeasuresOnce() {
        let (renderer, view) = makeRendered()
        let first = renderer.measuredSize(view, proposedWidth: 320)
        let second = renderer.measuredSize(view, proposedWidth: 320)
        #expect(first == second)
        #expect(renderer.measurePasses == 1)
        #expect(first.height > 0)
    }

    @Test("宽度变化或内容变化才重新测量")
    func widthOrContentChangeRemeasures() {
        let (renderer, view) = makeRendered()
        let wide = renderer.measuredSize(view, proposedWidth: 600)
        let narrow = renderer.measuredSize(view, proposedWidth: 200)
        #expect(renderer.measurePasses == 2)
        #expect(narrow.height > wide.height)
        // 内容追加 → 修订变化 → 重新测量
        renderer.apply(blocks + [.paragraph("追加的新段落")], to: view)
        _ = renderer.measuredSize(view, proposedWidth: 200)
        #expect(renderer.measurePasses == 3)
        // 再次同宽:命中
        _ = renderer.measuredSize(view, proposedWidth: 200)
        #expect(renderer.measurePasses == 3)
    }

    @Test("nil / 0 / 非有限提议沿用上次宽度,不改容器宽度、不重排")
    func degenerateProposalKeepsWidth() {
        let (renderer, view) = makeRendered()
        let base = renderer.measuredSize(view, proposedWidth: 360)
        let containerWidth = view.textContainer?.size.width
        for proposal in [nil, 0, .infinity, .nan] as [CGFloat?] {
            #expect(renderer.measuredSize(view, proposedWidth: proposal) == base)
        }
        #expect(renderer.measurePasses == 1)
        #expect(view.textContainer?.size.width == containerWidth)
    }

    @Test("从未测量过时,nil 提议使用容器当前宽度而不是另一个固定值")
    func firstNilProposalUsesContainerWidth() {
        let (renderer, view) = makeRendered()
        let containerWidth = view.textContainer?.size.width ?? 0
        let size = renderer.measuredSize(view, proposedWidth: nil)
        #expect(size.width == containerWidth)
    }

    @Test("缓存高度与直接排版一致")
    func cachedMatchesDirectMeasure() {
        let (renderer, view) = makeRendered()
        let cached = renderer.measuredSize(view, proposedWidth: 280)
        let direct = MarkdownTextRepresentable.measure(view, width: 280)
        #expect(cached == direct)
    }

    @Test("颜色没变:重复应用外观只生效一次(新建的等值 NSColor 不算变化)")
    func appearanceAppliedOnlyWhenChanged() {
        let (renderer, view) = makeRendered()
        func apply(_ alpha: CGFloat) -> Bool {
            renderer.applyAppearance(
                to: view,
                codeFill: NSColor(srgbRed: 0.9, green: 0.4, blue: 0.2, alpha: 0.1),
                quoteBar: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                linkColor: NSColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1),
                selectionColor: NSColor(srgbRed: 0.9, green: 0.4, blue: 0.2, alpha: alpha)
            )
        }
        #expect(apply(0.2))
        #expect(!apply(0.2))
        #expect(!apply(0.2))
        #expect(renderer.appearanceApplications == 1)
        #expect(apply(0.3))
        #expect(renderer.appearanceApplications == 2)
        let layout = view.layoutManager as? MarkdownLayoutManager
        #expect(layout != nil)
    }
}
