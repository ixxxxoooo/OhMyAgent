// @author ixxxxoooo
// 缩略图(I7):Retina 位图按点坐标绘制,第 N 行的条形落在第 N 个 2pt 行,不缩一半、不落到下半部。

import AppKit
import Testing
@testable import EditorKit

@MainActor
@Suite("编辑器缩略图")
struct EditorMinimapTests {
    /// 创建带缩略图、放进窗口的编辑器。
    private func makeEditor() -> (CodeEditorView, NSWindow) {
        let editor = CodeEditorView(isEditable: true)
        editor.chrome = [.minimap]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC 管理生命周期,关闭时不要再 release
        window.contentView = editor
        window.layoutIfNeeded()
        return (editor, window)
    }

    /// 位图某个点坐标处(y 向下)是否有墨迹。
    private func hasInk(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, scale: CGFloat) -> Bool {
        (rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? 0) > 0
    }

    @Test("2x 位图:首行条形在顶部且宽度按点计算,下半部无条形")
    func barsUseFullScaleFromTop() throws {
        let (editor, window) = makeEditor()
        defer { window.close() }
        editor.setText((0..<10).map { _ in String(repeating: "x", count: 60) }.joined(separator: "\n"), language: .plain)
        let minimap = try #require(editor.minimap)
        window.layoutIfNeeded()
        let scale: CGFloat = 2
        let rep = try #require(minimap.barsImage(scale: scale))
        #expect(rep.pixelsHigh == Int((minimap.bounds.height * scale).rounded(.up)))
        // 60 字符的条宽 = 60 × (84 − 10) / 120 ≈ 37pt,从 x = 5 开始
        #expect(hasInk(rep, x: 6, y: 0.5, scale: scale))
        #expect(hasInk(rep, x: 40, y: 0.5, scale: scale))
        #expect(hasInk(rep, x: 6, y: 19, scale: scale))      // 第 10 行(y 18–19.5)
        #expect(!hasInk(rep, x: 6, y: 21, scale: scale))     // 第 10 行之后为空
        #expect(!hasInk(rep, x: 6, y: minimap.bounds.height / 2 + 1, scale: scale))
    }
}
