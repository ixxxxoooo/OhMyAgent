// @author ixxxxoooo
// 签名帮助触发规则与富文本渲染。

import AppKit
import Testing
@testable import EditorKit

@Suite("签名帮助")
struct SignatureHelpTests {
    @Test("`(` 与 `,` 之后触发,其余字符不触发")
    func triggers() {
        #expect(EditorSignatureTrigger.shouldRequest(in: "f(", caret: 2))
        #expect(EditorSignatureTrigger.shouldRequest(in: "f(a,", caret: 4))
        #expect(!EditorSignatureTrigger.shouldRequest(in: "f(a", caret: 3))
        #expect(!EditorSignatureTrigger.shouldRequest(in: "", caret: 0))
        #expect(!EditorSignatureTrigger.shouldRequest(in: "f(", caret: 9))
    }

    @Test("未闭合括号判断:嵌套、已闭合、跨行")
    func unclosed() {
        #expect(EditorSignatureTrigger.hasUnclosedParen(in: "f(a, g(b", caret: 8))
        #expect(EditorSignatureTrigger.hasUnclosedParen(in: "f(a, g(b)", caret: 9))   // 外层仍未闭合
        #expect(!EditorSignatureTrigger.hasUnclosedParen(in: "f(a)", caret: 4))
        #expect(!EditorSignatureTrigger.hasUnclosedParen(in: "let x = 1", caret: 9))
        #expect(EditorSignatureTrigger.hasUnclosedParen(in: "f(\n  a,\n  b", caret: 11))
    }

    @MainActor
    @Test("当前参数被加粗并着色;范围越界时不崩溃")
    func attributed() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let signature = EditorSignature(label: "f(a: Int, b: String)", activeParameter: NSRange(location: 10, length: 9))
        let text = EditorSignatureTrigger.attributed(signature, font: font, normal: .gray, highlight: .red)
        #expect(text.string == signature.label)
        #expect(text.attribute(.foregroundColor, at: 12, effectiveRange: nil) as? NSColor == .red)
        #expect(text.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == .gray)
        let broken = EditorSignature(label: "f()", activeParameter: NSRange(location: 5, length: 9))
        #expect(EditorSignatureTrigger.attributed(broken, font: font, normal: .gray, highlight: .red).string == "f()")
    }
}
