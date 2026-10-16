// @author ixxxxoooo
// 输入框粘贴测试:剪贴板里只有图片/文件时粘贴可用;图片走附件,文字按纯文本插入。

import AppKit
import ChatKit
import Foundation
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("输入框粘贴行为")
struct ComposerPasteBehaviorTests {
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("oma.paste.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    private func makeView() -> SubmitTextView {
        let view = SubmitTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        view.acceptsImages = { true }
        return view
    }

    private func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    @Test("空剪贴板不可粘贴;文字、图片都可粘贴")
    func hasContent() {
        let empty = board()
        #expect(!SubmitTextView.pasteboardHasContent(empty))
        let text = board()
        text.setString("你好", forType: .string)
        #expect(SubmitTextView.pasteboardHasContent(text))
        let image = board()
        image.setData(png(), forType: .png)
        #expect(SubmitTextView.pasteboardHasContent(image))
    }

    @Test("只含图片的剪贴板:读取类型包含图片,粘贴被接管为附件")
    func imageOnly() {
        let view = makeView()
        #expect(view.readablePasteboardTypes.contains(.png))
        var received = 0
        view.onImages = { received += $0.count }
        let image = board()
        image.setData(png(), forType: .png)
        #expect(view.handlePasteboard(image))
        #expect(received == 1)
    }

    @Test("纯文字剪贴板不被接管,按纯文本插入光标处")
    func plainText() {
        let view = makeView()
        view.string = "ab"
        view.setSelectedRange(NSRange(location: 1, length: 0))
        let text = board()
        text.setString("XY", forType: .string)
        #expect(!view.handlePasteboard(text))
        view.insertPlainText(from: text)
        #expect(view.string == "aXYb")
    }

    @Test("删除内联 chip:文本存储与草稿纯文本同步移除")
    func removeMention() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oma-chip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = makeView()
        view.mentionWorkspace = dir
        view.setContent(plain: "看 @a.txt 然后", allowTrailingEnd: false, selection: NSRange(location: 0, length: 0))
        let chip = try #require(view.mentionAttachments.first)
        view.removeMention(chip.attachment, near: chip.location)
        #expect(view.mentionAttachments.isEmpty)
        #expect(!view.plainText.contains("@a.txt"))
    }
}
