// @author ygw
import AppKit
import ChatKit
import EditorKit
import Foundation
import Testing

/// 编辑器字体偏好:字号夹取、字体族解析与回退、行高换算、偏好键一致性。
@MainActor
@Suite("编辑器字体")
struct EditorFontTests {
    @Test("字号默认 13,并夹在 11–20 之间")
    func clampedSize() {
        #expect(EditorFontPrefs.clampedSize(nil) == 13)
        #expect(EditorFontPrefs.clampedSize(.nan) == 13)
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
