// @author ixxxxoooo
// 输入框内联文件 chip 的纯逻辑测试:片段切分、往返一致、光标坐标换算。

import Foundation
import Testing
@testable import ChatKit

@Suite("输入框内联提及")
struct ComposerMentionLayoutTests {
    private let workspace = URL(fileURLWithPath: "/ws")

    private func fake(_ path: String) -> Bool? {
        switch path {
        case "/ws/a.swift", "/ws/my docs/b.md": return false
        case "/ws/Sources": return true
        default: return nil
        }
    }

    @Test("后面跟空白的提及变成 chip,片段拼回等于原文")
    func piecesRoundTrip() {
        let text = "看 @a.swift 和 @\"my docs/b.md\" 以及 @Sources/ 完"
        let pieces = ComposerMentionLayout.pieces(for: text, workspace: workspace, allowTrailingEnd: false, exists: fake)
        let mentions = pieces.compactMap { piece -> String? in
            if case .mention(let mention) = piece { return mention.name }
            return nil
        }
        #expect(mentions == ["a.swift", "b.md", "Sources"])
        #expect(ComposerMentionLayout.plainText(of: pieces) == text)
    }

    @Test("用户还在输入的末尾提及不抢先变 chip,外部整体赋值时才变")
    func trailingEnd() {
        let typing = ComposerMentionLayout.pieces(for: "看 @a.swift", workspace: workspace, allowTrailingEnd: false, exists: fake)
        #expect(typing == [.text("看 @a.swift")])
        let assigned = ComposerMentionLayout.pieces(for: "看 @a.swift", workspace: workspace, allowTrailingEnd: true, exists: fake)
        #expect(assigned.count == 2)
    }

    @Test("同一路径重复出现每处都变 chip;不存在的路径与 @agent 保持文字")
    func duplicatesAndNonFiles() {
        let text = "@a.swift 再看 @a.swift @agent-x @nothing "
        let pieces = ComposerMentionLayout.pieces(for: text, workspace: workspace, allowTrailingEnd: false, exists: fake)
        let count = pieces.filter { if case .mention = $0 { return true } else { return false } }.count
        #expect(count == 2)
        #expect(ComposerMentionLayout.plainText(of: pieces) == text)
    }

    @Test("光标坐标在纯文本与存储之间互相换算")
    func offsetMapping() {
        // 纯文本 "ab @a.swift cd":记号长 8,位于纯文本 3;存储里变成 "ab \u{FFFC} cd"
        let spans = [ComposerMentionLayout.Span(storageLocation: 3, tokenLength: 8)]
        #expect(ComposerMentionLayout.plainOffset(storage: 3, spans: spans) == 3)
        #expect(ComposerMentionLayout.plainOffset(storage: 4, spans: spans) == 11)
        #expect(ComposerMentionLayout.plainOffset(storage: 6, spans: spans) == 13)
        #expect(ComposerMentionLayout.storageOffset(plain: 3, spans: spans) == 3)
        #expect(ComposerMentionLayout.storageOffset(plain: 7, spans: spans) == 3)
        #expect(ComposerMentionLayout.storageOffset(plain: 11, spans: spans) == 4)
        #expect(ComposerMentionLayout.storageOffset(plain: 13, spans: spans) == 6)
    }

    @Test("多个附件的换算累计")
    func multipleSpans() {
        let spans = [
            ComposerMentionLayout.Span(storageLocation: 0, tokenLength: 4),
            ComposerMentionLayout.Span(storageLocation: 2, tokenLength: 6),
        ]
        // 纯文本 "@a.b " + "@c.dd " 对应存储 [chip][空格][chip][空格]
        #expect(ComposerMentionLayout.plainOffset(storage: 4, spans: spans) == 4 + 3 + 5)
        #expect(ComposerMentionLayout.storageOffset(plain: 12, spans: spans) == 4)
    }
}
