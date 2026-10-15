// @author ygw
// 并排 Diff 视图渲染冒烟测试:能渲染出非空图像(设置 SBS_DUMP 时落盘 PNG 供人工查看)。

import AppKit
import DiffKit
import SwiftUI
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("并排 Diff 渲染")
struct SideBySideRenderTests {
    @Test("渲染非空")
    func renders() throws {
        let old = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 3\n", with: "edited three\nextra\n")
            .replacingOccurrences(of: "line 9\n", with: "")
        let diff = LineDiff.diff(old: old, new: new)
        let view = SideBySideDiffView(diff: diff, onRevertHunk: { _ in })
            .frame(width: 720)
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.height > 60)
        if let path = ProcessInfo.processInfo.environment["SBS_DUMP"],
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
