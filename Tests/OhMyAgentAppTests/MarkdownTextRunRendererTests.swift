// @author ixxxxoooo
// Markdown 文字段渲染器:按块缓存富文本 + 对文本存储做尾部增量替换,结果必须与整段重建逐字符、逐属性一致。

import AppKit
import ChatKit
import DesignSystem
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("Markdown 文字段渲染器", .serialized)
struct MarkdownTextRunRendererTests {
    /// 取一段文字的文字块(不含围栏代码块的回复,整体是一个文字段)。
    private func textBlocks(_ text: String) -> [MarkdownBlock] {
        let blocks = MarkdownParser.parse(text)
        return blocks.filter(isTextRunBlock)
    }

    /// 整段重建的参照:同样放进 `NSTextStorage`(存储会补全缺省字体等属性,直接和未放进存储的富文本比较会不相等)。
    private func reference(_ blocks: [MarkdownBlock]) -> NSTextStorage {
        NSTextStorage(attributedString: MarkdownTextRunBuilder.build(blocks))
    }

    @Test("流式逐片追加:每一步增量结果都等于整段重建(含属性)")
    func incrementalMatchesFullRebuild() {
        let full = StreamingBench.sampleReply(kilobytes: 3)
        let renderer = MarkdownTextRunRenderer()
        let view = MarkdownTextRepresentable.makeTextView()
        var prefix = ""
        for piece in StreamingBench.chunks(of: full, size: 37) {
            prefix += piece
            let blocks = textBlocks(prefix)
            renderer.apply(blocks, to: view)
            guard let storage = view.textStorage else { Issue.record("没有文本存储"); return }
            #expect(storage.isEqual(to: reference(blocks)), "前缀长度 \(prefix.count) 时增量结果与整段重建不一致")
        }
        #expect(renderer.incrementalUpdates > 0)
    }

    @Test("内容不变时不改动文本存储")
    func unchangedContentIsNoOp() {
        let blocks = textBlocks("第一段\n\n- 项一\n- 项二\n")
        let renderer = MarkdownTextRunRenderer()
        let view = MarkdownTextRepresentable.makeTextView()
        renderer.apply(blocks, to: view)
        let before = renderer.edits
        renderer.apply(blocks, to: view)
        #expect(renderer.edits == before)
    }

    @Test("块被改写(非追加)时从第一个不同的块起重换,前缀块保持")
    func editInTheMiddleReplacesFromFirstDifference() {
        let renderer = MarkdownTextRunRenderer()
        let view = MarkdownTextRepresentable.makeTextView()
        renderer.apply([.paragraph("甲"), .paragraph("乙"), .paragraph("丙")], to: view)
        renderer.apply([.paragraph("甲"), .paragraph("乙乙"), .paragraph("丙")], to: view)
        #expect(view.textStorage?.isEqual(to: reference([.paragraph("甲"), .paragraph("乙乙"), .paragraph("丙")])) == true)
    }

    @Test("块减少(缩短)时也与整段重建一致")
    func shrinkingMatchesFullRebuild() {
        let renderer = MarkdownTextRunRenderer()
        let view = MarkdownTextRepresentable.makeTextView()
        renderer.apply([.paragraph("甲"), .paragraph("乙"), .paragraph("丙")], to: view)
        renderer.apply([.paragraph("甲")], to: view)
        #expect(view.textStorage?.isEqual(to: reference([.paragraph("甲")])) == true)
        renderer.apply([], to: view)
        #expect(view.textStorage?.length == 0)
    }

    @Test("字号缩放变化后整体重建,不沿用旧样式的缓存")
    func scaleChangeInvalidatesCache() {
        let renderer = MarkdownTextRunRenderer()
        let view = MarkdownTextRepresentable.makeTextView()
        let blocks: [MarkdownBlock] = [.paragraph("样式随字号变化"), .paragraph("第二段")]
        let original = OMScale.timeline
        defer { OMScale.timeline = original }
        renderer.apply(blocks, to: view)
        let before = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        OMScale.timeline = original * 1.5
        renderer.apply(blocks, to: view)
        let after = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect((after?.pointSize ?? 0) > (before?.pointSize ?? 0))
    }

    @Test("增量更新后选区在未改动的前缀里保持不变")
    func selectionInPrefixSurvivesAppend() {
        let renderer = MarkdownTextRunRenderer()
        let view = MarkdownTextRepresentable.makeTextView()
        renderer.apply([.paragraph("第一段文字"), .paragraph("第二")], to: view)
        view.setSelectedRange(NSRange(location: 0, length: 3))
        renderer.apply([.paragraph("第一段文字"), .paragraph("第二段继续")], to: view)
        #expect(view.selectedRange() == NSRange(location: 0, length: 3))
    }
}
