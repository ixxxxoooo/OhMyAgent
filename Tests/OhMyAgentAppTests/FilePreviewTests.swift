// @author ygw
// 文件渲染预览:类型识别、CSV 解析、SVG 能被系统渲染。

import AppKit
import SwiftUI
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("文件预览")
struct FilePreviewTests {
    @Test("按扩展名识别预览类型")
    func kinds() {
        #expect(FilePreviewKind.of(path: "/a/README.md") == .markdown)
        #expect(FilePreviewKind.of(path: "/a/g.MMD") == .mermaid)
        #expect(FilePreviewKind.of(path: "/a/i.svg") == .svg)
        #expect(FilePreviewKind.of(path: "/a/i.PNG") == .image)
        #expect(FilePreviewKind.of(path: "/a/d.pdf") == .pdf)
        #expect(FilePreviewKind.of(path: "/a/t.csv") == .csv(delimiter: ","))
        #expect(FilePreviewKind.of(path: "/a/t.tsv") == .csv(delimiter: "\t"))
        #expect(FilePreviewKind.of(path: "/a/main.swift") == nil)
        #expect(FilePreviewKind.image.isBinary)
        #expect(!FilePreviewKind.markdown.isBinary)
    }

    @Test("CSV:引号、转义、换行与空行")
    func csv() {
        let text = "name,note\r\n\"Li, Wei\",\"say \"\"hi\"\"\"\n\"multi\nline\",x\n\n"
        let rows = CSVParser.parse(text, delimiter: ",")
        #expect(rows.count == 3)
        #expect(rows[0] == ["name", "note"])
        #expect(rows[1] == ["Li, Wei", "say \"hi\""])
        #expect(rows[2] == ["multi\nline", "x"])
    }

    @Test("CSV:TSV 与行数上限")
    func tsvAndLimit() {
        #expect(CSVParser.parse("a\tb\n1\t2", delimiter: "\t") == [["a", "b"], ["1", "2"]])
        let big = (0..<100).map { "\($0),x" }.joined(separator: "\n")
        #expect(CSVParser.parse(big, delimiter: ",", maxRows: 10).count == 10)
    }

    @Test("SVG 文本可被系统渲染为图片")
    func svgRenders() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"><rect width=\"40\" height=\"20\" fill=\"red\"/></svg>"
        let image = NSImage(data: Data(svg.utf8))
        #expect(image != nil)
        #expect((image?.size.width ?? 0) > 0)
    }

    @Test("Markdown 预览渲染非空(设置 PREVIEW_DUMP 时落盘 PNG)")
    func markdownPreviewRenders() throws {
        let text = "# 标题\n\n正文 **粗体** 与 `code`。\n\n```swift\nlet x = 42 // note\nfunc f() {}\n```\n\n- 项一\n- 项二\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        let view = MarkdownView(text: text).padding(20).frame(width: 560)
            .background(Color(nsColor: .textBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.height > 100)
        if let path = ProcessInfo.processInfo.environment["PREVIEW_DUMP"],
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
