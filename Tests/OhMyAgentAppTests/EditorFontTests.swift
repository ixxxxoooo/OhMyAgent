// @author ixxxxoooo
import AppKit
import ChatKit
import EditorKit
import Foundation
import Testing

/// 编辑器字体偏好:字号夹取、字体族解析与回退、行高换算、偏好键一致性。
@MainActor
@Suite("编辑器字体")
struct EditorFontTests {
    @Test("字号默认 12,并夹在 11–20 之间")
    func clampedSize() {
        #expect(EditorFontPrefs.clampedSize(nil) == 12)
        #expect(EditorFontPrefs.clampedSize(.nan) == 12)
        #expect(EditorFontPrefs.clampedSize(9) == 11)
        #expect(EditorFontPrefs.clampedSize(12.5) == 12.5)
        #expect(EditorFontPrefs.clampedSize(28) == 20)
    }

    @Test("字体族规整:空串与系统等宽写法统一")
    func normalizedFamily() {
        #expect(EditorFontPrefs.normalizedFamily(nil) == EditorFontPrefs.systemMonospace)
        #expect(EditorFontPrefs.normalizedFamily("  ") == EditorFontPrefs.systemMonospace)
        #expect(EditorFontPrefs.normalizedFamily("system monospace") == EditorFontPrefs.systemMonospace)
        #expect(EditorFontPrefs.normalizedFamily(" Menlo ") == "Menlo")
    }

    @Test("系统等宽与未安装字体都回退到系统等宽")
    func fallsBackToSystemMonospace() {
        let system = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        #expect(EditorFontPrefs.font(family: EditorFontPrefs.systemMonospace, size: 13) == system)
        #expect(EditorFontPrefs.font(family: "这个字体不存在 XYZ", size: 13) == system)
        #expect(!EditorFontPrefs.isInstalled("这个字体不存在 XYZ"))
    }

    @Test("已安装字体按字体族解析并带上字号")
    func resolvesInstalledFamily() {
        #expect(EditorFontPrefs.isInstalled("Menlo"))
        let font = EditorFontPrefs.font(family: "Menlo", size: 15)
        #expect(font.familyName == "Menlo")
        #expect(font.pointSize == 15)
    }

    @Test("行高:13pt 总行高为 18,字号等比缩放,自然行高超出目标时不压缩")
    func lineHeight() {
        for size in [13.0, 16.0, 20.0] {
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let natural = font.ascender - font.descender + font.leading
            let spacing = EditorFontPrefs.lineSpacing(for: font)
            #expect(abs(natural + spacing - size * 18 / 13) < 0.01)
        }
        let big = NSFont.monospacedSystemFont(ofSize: 40, weight: .regular)
        #expect(EditorFontPrefs.lineSpacing(for: big) >= 0)
        let style = EditorFontPrefs.paragraphStyle(for: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        #expect(style.lineSpacing > 0)
    }

    @Test("应用新主题后,已有文本的字体与行高随之更新")
    func applyThemeUpdatesExistingText() throws {
        let view = CodeEditorView(isEditable: false)
        view.setText("let a = 1\nlet b = 2\n", language: .swift)
        var theme = EditorTheme.default
        theme.font = EditorFontPrefs.font(family: "Menlo", size: 18)
        view.apply(theme: theme)

        #expect(view.textView.font?.familyName == "Menlo")
        let storage = try #require(view.textView.textStorage)
        let font = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.familyName == "Menlo")
        #expect(font.pointSize == 18)
        let style = try #require(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.lineSpacing == EditorFontPrefs.lineSpacing(for: theme.font))
    }

    @Test("偏好变化后,已打开的编辑器自动换成新字体与字号")
    func openEditorFollowsPrefChanges() async throws {
        let defaults = UserDefaults.standard
        let oldFamily = defaults.object(forKey: EditorFontPrefs.familyKey)
        let oldSize = defaults.object(forKey: EditorFontPrefs.sizeKey)
        defer {
            defaults.set(oldFamily, forKey: EditorFontPrefs.familyKey)
            defaults.set(oldSize, forKey: EditorFontPrefs.sizeKey)
        }
        let view = CodeEditorView(isEditable: false)
        view.setText("let a = 1\n", language: .swift)

        defaults.set("Menlo", forKey: EditorFontPrefs.familyKey)
        defaults.set(17.0, forKey: EditorFontPrefs.sizeKey)
        // 通知回调会先切回主线程再刷新,稍等片刻
        try await Task.sleep(for: .milliseconds(150))

        #expect(view.textView.font?.familyName == "Menlo")
        #expect(view.textView.font?.pointSize == 17)
        let storage = try #require(view.textView.textStorage)
        let font = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 17)
    }

    @Test("预置字体第一项是系统等宽")
    func presetsStartWithSystem() {
        #expect(EditorFontPrefs.presets.first?.value == EditorFontPrefs.systemMonospace)
        #expect(Set(EditorFontPrefs.presets.map(\.value)).count == EditorFontPrefs.presets.count)
    }

    @Test("设置页偏好键与编辑器读取的键一致")
    func prefKeysMatch() {
        #expect(ClientPrefs.Key.editorFontSize == EditorFontPrefs.sizeKey)
        #expect(ClientPrefs.Key.editorFontFamily == EditorFontPrefs.familyKey)
    }
}
