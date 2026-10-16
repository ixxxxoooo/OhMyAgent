// @author ygw
// 编辑器内 Markdown 就地渲染:标题放大、标记符折叠、光标进入块后展开、源码模式不改字体。

import AppKit
import EditorKit
import Foundation
import Testing

@MainActor
@Suite("编辑器 Markdown 渲染")
struct MarkdownEditorRenderTests {
    private let source = "# 标题\n\n正文 **粗体** 与 `code`。\n\n```swift\nlet x = 42\n```\n\n- 项一\n"

    private func makeEditor(mode: MarkdownEditorMode) async -> (CodeEditorView, NSWindow) {
        let view = CodeEditorView(isEditable: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.markdownMode = mode
        view.setText(source, language: .markdown)
        await settle { mode != .live || (self.font(view, at: 0)?.pointSize ?? 10) < 1 }
        return (view, window)
    }

    /// 轮询等待条件成立(最多 5 秒),避免固定睡眠在高负载下不稳定。
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func font(_ view: CodeEditorView, at location: Int) -> NSFont? {
        view.textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    @Test("就地渲染:标题放大,标记符折叠")
    func liveStyles() async throws {
        let (view, _) = await makeEditor(mode: .live)
        let heading = try #require(font(view, at: 3)) // “标题”
        let body = try #require(font(view, at: 12))
        #expect(heading.pointSize > body.pointSize + 4)
        let marker = try #require(font(view, at: 0)) // “# ”
        #expect(marker.pointSize < 1)
        // 加粗内容使用粗体
        let ns = view.textView.string as NSString
        let boldLocation = ns.range(of: "粗体").location
        let bold = try #require(font(view, at: boldLocation))
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        // 围栏标记符折叠、围栏内关键字有语法色
        let fence = ns.range(of: "```swift").location
        #expect((font(view, at: fence)?.pointSize ?? 10) < 1)
        let letLocation = ns.range(of: "let x").location
        let color = view.textView.textStorage?.attribute(.foregroundColor, at: letLocation, effectiveRange: nil) as? NSColor
        #expect(color != nil)
    }

    @Test("光标进入块后该块的标记符展开")
    func activeBlockReveals() async throws {
        let (view, window) = await makeEditor(mode: .live)
        window.makeFirstResponder(view.textView)
        view.textView.setSelectedRange(NSRange(location: 3, length: 0))
        await settle { (self.font(view, at: 0)?.pointSize ?? 0) > 5 }
        let marker = try #require(font(view, at: 0))
        #expect(marker.pointSize > 5)
        // 光标移到别处,标题块重新折叠
        let ns = view.textView.string as NSString
        view.textView.setSelectedRange(NSRange(location: ns.range(of: "项一").location, length: 0))
        await settle { (self.font(view, at: 0)?.pointSize ?? 10) < 1 }
        #expect((font(view, at: 0)?.pointSize ?? 10) < 1)
    }

    @Test("源码模式:保持等宽,不折叠标记符")
    func sourceMode() async throws {
        let (view, _) = await makeEditor(mode: .source)
        let marker = try #require(font(view, at: 0))
        #expect(marker.pointSize > 5)
        #expect(marker.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    @Test("编辑后重新渲染(新增标题立即折叠标记符)")
    func rerenderAfterEdit() async throws {
        let (view, _) = await makeEditor(mode: .live)
        view.setText("## 新标题\n", language: .markdown)
        await settle { (self.font(view, at: 0)?.pointSize ?? 10) < 1 && (self.font(view, at: 4)?.pointSize ?? 0) > 15 }
        #expect((font(view, at: 0)?.pointSize ?? 10) < 1)
        #expect((font(view, at: 4)?.pointSize ?? 0) > 15)
    }

    @Test("渲染快照(设置 MD_DUMP 时落盘 PNG)")
    func snapshot() async throws {
        let (view, window) = await makeEditor(mode: .live)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let path = ProcessInfo.processInfo.environment["MD_DUMP"] else { return }
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
