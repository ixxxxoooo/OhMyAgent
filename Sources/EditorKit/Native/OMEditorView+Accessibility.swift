// @author ixxxxoooo
// 原生编辑视图的无障碍:以「多行文本区」暴露全文、选区、可见区间与按行/按范围的查询,供 VoiceOver 朗读与导航。

import AppKit
import EditorCore

extension OMEditorView {
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    public override func accessibilityLabel() -> String? { String(localized: "代码编辑器") }

    /// 全文(超大文件只返回前 200 万个字符,避免无障碍请求拖慢主线程)。
    public override func accessibilityValue() -> Any? {
        let length = min(model.document.length, 2_000_000)
        return model.document.snapshot.string(in: TextSpan(location: 0, length: length))
    }

    public override func accessibilityNumberOfCharacters() -> Int { model.document.length }

    public override func accessibilitySelectedText() -> String? {
        let range = model.selections.primary.range
        return model.document.snapshot.string(in: range)
    }

    public override func accessibilitySelectedTextRange() -> NSRange {
        let range = model.selections.primary.range
        return NSRange(location: range.location, length: range.length)
    }

    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        let length = model.document.length
        let lower = min(max(range.location, 0), length)
        let upper = min(max(range.location + range.length, lower), length)
        model.setSelections(SelectionSet([Selection(anchor: lower, head: upper)]))
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange { visibleOffsetRange() }

    public override func accessibilityInsertionPointLineNumber() -> Int {
        model.document.snapshot.line(containing: model.selections.primary.head)
    }

    public override func accessibilityRange(forLine line: Int) -> NSRange {
        guard let range = model.document.snapshot.lineRange(line) else { return NSRange(location: 0, length: 0) }
        return NSRange(location: range.location, length: range.length)
    }

    public override func accessibilityLine(for index: Int) -> Int {
        model.document.snapshot.line(containing: min(max(index, 0), model.document.length))
    }

    public override func accessibilityString(for range: NSRange) -> String? {
        let length = model.document.length
        let lower = min(max(range.location, 0), length)
        let upper = min(max(range.location + range.length, lower), length)
        return model.document.snapshot.string(in: TextSpan(lower: lower, upper: upper))
    }

    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        let rect = caretRect(forOffset: min(max(range.location, 0), model.document.length), width: 2)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }
}
