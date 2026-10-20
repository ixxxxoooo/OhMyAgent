// @author ixxxxoooo
// 时间线用户消息里的文件引用 chip:富文本构造、复制还原为记号、切片复制。

import AppKit
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("用户消息文件引用 chip", .serialized)
struct MentionChipLeafTests {
    private let workspace = URL(fileURLWithPath: "/tmp/oma-chip-ws")

    /// 假文件系统:只认 `a.swift`(文件)。
    private func exists(_ path: String) -> Bool? {
        path.hasSuffix("/a.swift") ? false : nil
    }

    private func build(_ text: String) -> NSAttributedString {
        OMLeafContent.userMessage(text, workspace: workspace, size: 13, color: .labelColor, exists: exists)
    }

    @Test("有效引用变成 1 个附件字符,复制还原为 @记号")
    func mentionBecomesAttachment() {
        let attributed = build("看看 @a.swift 的实现")
        #expect(attributed.length < "看看 @a.swift 的实现".utf16.count)
        var attachments = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        #expect(attachments == 1)
        let copied = OMReadOnlyTextView.copyText(of: attributed, range: NSRange(location: 0, length: attributed.length), transform: nil)
        #expect(copied == "看看 @a.swift 的实现")
    }

    @Test("不存在的引用与没有 @ 的文字保持纯文本")
    func nonexistentStaysPlain() {
        #expect(build("邮箱 me@x.com 不是引用").string == "邮箱 me@x.com 不是引用")
        #expect(build("@nope.swift 不存在").string == "@nope.swift 不存在")
        #expect(build("普通文字").string == "普通文字")
    }

    @Test("切片复制:只选中 chip 前的文字时不带记号,选中 chip 时带记号")
    func partialSelection() {
        let attributed = build("前 @a.swift 后")
        // 布局:「前 」(2) + chip(1) + 「 后」(2)
        #expect(attributed.length == 5)
        #expect(OMReadOnlyTextView.copyText(of: attributed, range: NSRange(location: 0, length: 2), transform: nil) == "前 ")
        #expect(OMReadOnlyTextView.copyText(of: attributed, range: NSRange(location: 2, length: 1), transform: nil) == "@a.swift")
        #expect(OMReadOnlyTextView.copyText(of: attributed, range: NSRange(location: 2, length: 3), transform: nil) == "@a.swift 后")
    }

    @Test("越界范围返回空串且不崩溃")
    func outOfRange() {
        let attributed = build("abc")
        #expect(OMReadOnlyTextView.copyText(of: attributed, range: NSRange(location: 2, length: 9), transform: nil).isEmpty)
    }
}
