// @author ixxxxoooo
// 图片摄取测试:粘贴板里的截图数据、文件 URL、TIFF 都能变成可发送的附件;非图片被忽略。

import AppKit
import ChatKit
import Foundation
import Testing
@testable import OhMyAgentApp

/// 生成一张纯色 PNG 数据。
private func pngData(width: Int = 64, height: Int = 48) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    guard let rep, let data = rep.representation(using: .png, properties: [:]) else { return Data() }
    return data
}

@MainActor
@Suite("图片摄取")
struct ImageIntakeTests {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("oma.test.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    @Test("截图(PNG 数据)可作为附件")
    func pngData_() {
        let board = pasteboard()
        board.setData(pngData(), forType: .png)
        #expect(ImageIntake.hasImage(board))
        let items = ImageIntake.attachments(from: board)
        #expect(items.count == 1)
        #expect(items.first?.mimeType == "image/png")
    }

    @Test("TIFF 数据被转成 PNG")
    func tiff() throws {
        let board = pasteboard()
        let tiff = try #require(NSBitmapImageRep(data: pngData())?.tiffRepresentation)
        board.setData(tiff, forType: .tiff)
        #expect(ImageIntake.hasImage(board))
        #expect(ImageIntake.attachments(from: board).first?.mimeType == "image/png")
    }

    @Test("Finder 复制的图片文件(文件 URL)可作为附件")
    func fileURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oma-intake-\(UUID().uuidString).png")
        try pngData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let board = pasteboard()
        board.writeObjects([url as NSURL])
        #expect(ImageIntake.hasImage(board))
        let items = ImageIntake.attachments(from: board)
        #expect(items.count == 1)
        #expect(items.first?.name == url.lastPathComponent)
    }

    @Test("非图片文件与纯文本不会被当成图片")
    func notImages() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oma-intake-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let board = pasteboard()
        board.writeObjects([url as NSURL])
        #expect(!ImageIntake.hasImage(board))
        #expect(ImageIntake.attachments(from: board).isEmpty)
        let text = pasteboard()
        text.setString("你好", forType: .string)
        #expect(!ImageIntake.hasImage(text))
    }
}

@Suite("图片预览命名")
struct ImagePreviewNamingTests {
    @Test("补全缺失或不匹配的扩展名")
    func suggestedName() {
        #expect(ImagePreviewNaming.suggestedName("截图", mimeType: "image/png") == "截图.png")
        #expect(ImagePreviewNaming.suggestedName("a.png", mimeType: "image/png") == "a.png")
        #expect(ImagePreviewNaming.suggestedName("a.jpg", mimeType: "image/jpeg") == "a.jpg")
        #expect(ImagePreviewNaming.suggestedName("x/y", mimeType: "image/png") == "x-y.png")
    }
}

@MainActor
@Suite("输入框粘贴图片")
struct ComposerPasteTests {
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("oma.paste.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    private func makeView() -> (SubmitTextView, Box) {
        let box = Box()
        let view = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.acceptsImages = { true }
        view.onImages = { box.images += $0.count }
        view.onFileURLs = { box.files += $0.count }
        return (view, box)
    }

    @MainActor final class Box { var images = 0; var files = 0 }

    @Test("PNG 截图被接管为附件")
    func pastePNG() {
        let pb = board()
        pb.setData(pngData(), forType: .png)
        let (view, box) = makeView()
        #expect(view.handlePasteboard(pb))
        #expect(box.images == 1)
    }

    @Test("TIFF 与同时带链接文字(网页复制图片)也按图片处理")
    func pasteTIFFWithURLText() throws {
        let pb = board()
        let tiff = try #require(NSBitmapImageRep(data: pngData())?.tiffRepresentation)
        pb.setData(tiff, forType: .tiff)
        pb.setString("https://example.com/a.png", forType: .string)
        let (view, box) = makeView()
        #expect(view.handlePasteboard(pb))
        #expect(box.images == 1)
    }

    @Test("图片数据同时带正文文字(表格复制)时按文字粘贴")
    func pasteTextWins() throws {
        let pb = board()
        pb.setData(pngData(), forType: .png)
        pb.setString("姓名\t年龄\n张三\t18", forType: .string)
        let (view, box) = makeView()
        #expect(!view.handlePasteboard(pb))
        #expect(box.images == 0)
    }

    @Test("非图片文件转为文件引用,不当成图片")
    func pasteFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oma-paste-\(UUID().uuidString).txt")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let pb = board()
        pb.writeObjects([url as NSURL])
        let (view, box) = makeView()
        #expect(view.handlePasteboard(pb))
        #expect(box.images == 0)
        #expect(box.files == 1)
    }

    @Test("不接受图片时不接管")
    func disabled() {
        let pb = board()
        pb.setData(pngData(), forType: .png)
        let (view, box) = makeView()
        view.acceptsImages = { false }
        #expect(!view.handlePasteboard(pb))
        #expect(box.images == 0)
    }

    @Test("附带文字判定:空白与单条链接算附带,正文不算")
    func incidentalText() {
        #expect(ImageIntake.isIncidentalText(nil))
        #expect(ImageIntake.isIncidentalText("  \n"))
        #expect(ImageIntake.isIncidentalText("https://a.com/x.png"))
        #expect(!ImageIntake.isIncidentalText("hello world"))
        #expect(!ImageIntake.isIncidentalText("https://a.com\nmore"))
    }
}
