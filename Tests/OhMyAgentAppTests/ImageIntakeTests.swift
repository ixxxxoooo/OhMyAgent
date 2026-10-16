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
