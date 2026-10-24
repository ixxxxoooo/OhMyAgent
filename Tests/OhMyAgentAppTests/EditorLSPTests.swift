// @author ixxxxoooo
// 编辑器与语言服务器桥接测试:位置换算、诊断渲染、补全过滤、控制器端到端(脚本化服务器,不依赖真实工具链)。

import ACPKit
import AppKit
import EditorCore
import EditorKit
import Foundation
import LSPKit
import Synchronization
import Testing

@testable import OhMyAgentApp

@Suite("LSP 位置换算")
struct LSPTextMappingTests {
    @Test("偏移与位置互转(含多行与行尾)")
    func roundTrip() {
        let index = LineIndex(text: "ab\ncde\n\nf")
        #expect(LSPTextMapping.position(offset: 0, in: index) == LSPPosition(line: 0, character: 0))
        #expect(LSPTextMapping.position(offset: 4, in: index) == LSPPosition(line: 1, character: 1))
        #expect(LSPTextMapping.position(offset: 7, in: index) == LSPPosition(line: 2, character: 0))
        #expect(LSPTextMapping.position(offset: 9, in: index) == LSPPosition(line: 3, character: 1))
        for offset in 0...index.length {
            #expect(LSPTextMapping.offset(of: LSPTextMapping.position(offset: offset, in: index), in: index) == offset)
        }
    }

    @Test("UTF-16:emoji 占两个代码单元")
    func utf16() {
        let text = "a😀b\nx"
        let index = LineIndex(text: text)
        // a(0) 😀(1,2) b(3)
        #expect(LSPTextMapping.position(offset: 3, in: index) == LSPPosition(line: 0, character: 3))
        #expect(LSPTextMapping.offset(of: LSPPosition(line: 0, character: 3), in: index) == 3)
    }

    @Test("越界夹取:列越界到行尾(不含换行),行越界到文末,负数到 0")
    func clamping() {
        let index = LineIndex(text: "ab\ncd")
        #expect(LSPTextMapping.offset(of: LSPPosition(line: 0, character: 99), in: index) == 2)
        #expect(LSPTextMapping.offset(of: LSPPosition(line: 9, character: 0), in: index) == 5)
        #expect(LSPTextMapping.offset(of: LSPPosition(line: -1, character: 3), in: index) == 0)
        #expect(LSPTextMapping.offset(of: LSPPosition(line: 1, character: -2), in: index) == 3)
        #expect(LSPTextMapping.position(offset: 999, in: index) == LSPPosition(line: 1, character: 2))
    }

    @Test("诊断转换:级别、范围与来源")
    func diagnosticConversion() {
        let index = LineIndex(text: "let a = 1\nlet b = a")
        let items = [
            LSPDiagnostic(range: LSPRange(start: .init(line: 1, character: 8), end: .init(line: 1, character: 9)), severity: .warning, message: "w", source: "swift"),
            LSPDiagnostic(range: LSPRange(start: .init(line: 0, character: 4), end: .init(line: 0, character: 4)), message: "e"),
        ]
        let converted = LSPTextMapping.editorDiagnostics(items, in: index)
        #expect(converted[0] == EditorDiagnostic(range: NSRange(location: 18, length: 1), severity: .warning, message: "w  (swift)"))
        #expect(converted[1].severity == .error)
        #expect(converted[1].range == NSRange(location: 4, length: 0))
    }
}

@MainActor
@Suite("编辑器诊断渲染")
struct EditorDiagnosticsRenderTests {
    private func makeView(_ text: String, language: SyntaxLanguage) -> OMEditorView {
        let model = NativeEditorModel(document: EditorDocument(text: text), language: language)
        return OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
    }

    /// 某偏移处是否有诊断装饰(下划线)。
    private func hasDiagnostic(_ view: OMEditorView, at offset: Int) -> Bool {
        view.model.decorations.containing(offset: offset).contains {
            switch $0.kind {
            case .diagnosticError, .diagnosticWarning, .diagnosticInfo, .diagnosticHint: true
            default: false
            }
        }
    }

    @Test("诊断范围被标出,重设后旧标记被清除")
    func underlines() {
        let view = makeView("let value = 42\nprint(value)", language: .swift)
        view.setDiagnostics([EditorDiagnostic(range: NSRange(location: 4, length: 5), severity: .error, message: "bad")])
        #expect(hasDiagnostic(view, at: 5))
        #expect(hasDiagnostic(view, at: 8))
        #expect(!hasDiagnostic(view, at: 10))
        view.setDiagnostics([EditorDiagnostic(range: NSRange(location: 15, length: 5), severity: .warning, message: "w")])
        #expect(!hasDiagnostic(view, at: 5))
        #expect(hasDiagnostic(view, at: 16))
    }

    @Test("越界范围被夹取,不崩溃")
    func outOfRange() {
        let view = makeView("foo bar", language: .plain)
        view.setDiagnostics([
            EditorDiagnostic(range: NSRange(location: 4, length: 3), severity: .error, message: "x"),
            EditorDiagnostic(range: NSRange(location: 500, length: 10), severity: .warning, message: "越界"),
        ])
        #expect(hasDiagnostic(view, at: 5))
        #expect(hasDiagnostic(view, at: 6))
        #expect(!hasDiagnostic(view, at: 3))
    }

    @Test("清空诊断后标记全部消失")
    func clearing() {
        let view = makeView("abc", language: .plain)
        view.setDiagnostics([EditorDiagnostic(range: NSRange(location: 0, length: 3), severity: .error, message: "x")])
        #expect(hasDiagnostic(view, at: 1))
        view.setDiagnostics([])
        #expect(!hasDiagnostic(view, at: 1))
    }
}
