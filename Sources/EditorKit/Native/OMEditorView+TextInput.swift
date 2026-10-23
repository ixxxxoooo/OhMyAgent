// @author ixxxxoooo
// 原生编辑视图的系统文本输入协议(NSTextInputClient):普通输入、输入法组合文本、候选窗定位、字符反查。
// 组合文本直接写入文档并以 `composition` 标记(与 NSTextView 一致),确认或取消时再收口。

import AppKit
import EditorCore

extension OMEditorView: @preconcurrency NSTextInputClient {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard model.isEditable else { return }
        let text = Self.plainString(from: string)
        // 组合中:用最终文本替换整个组合区间。
        if let marked = composition {
            composition = nil
            model.insertText(text, replacing: TextSpan(location: marked.location, length: marked.length))
            return
        }
        if replacementRange.location != NSNotFound {
            model.insertText(text, replacing: TextSpan(location: replacementRange.location, length: replacementRange.length))
        } else {
            model.insertText(text)
        }
        languageController.didInsert(text)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard model.isEditable else { return }
        let text = Self.plainString(from: string)
        let target: TextSpan
        if let marked = composition {
            target = TextSpan(location: marked.location, length: marked.length)
        } else if replacementRange.location != NSNotFound {
            target = TextSpan(location: replacementRange.location, length: replacementRange.length)
        } else {
            let primary = model.selections.primary.range
            target = primary
        }
        let units = text.utf16.count
        model.replaceForComposition(target, with: text, selectedInside: selectedRange)
        composition = units > 0 ? NSRange(location: target.location, length: units) : nil
        needsDisplay = true
    }

    public func unmarkText() {
        composition = nil
        needsDisplay = true
    }

    public func selectedRange() -> NSRange {
        let range = model.selections.primary.range
        return NSRange(location: range.location, length: range.length)
    }

    public func markedRange() -> NSRange { composition ?? NSRange(location: NSNotFound, length: 0) }

    public func hasMarkedText() -> Bool { composition != nil }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let length = model.document.length
        let lower = min(max(range.location, 0), length)
        let upper = min(max(range.location + range.length, lower), length)
        actualRange?.pointee = NSRange(location: lower, length: upper - lower)
        return NSAttributedString(string: model.document.snapshot.string(in: TextSpan(lower: lower, upper: upper)))
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .underlineColor] }

    /// 输入法候选窗锚点:字符区间起点所在行的屏幕矩形。
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let offset = min(max(range.location, 0), model.document.length)
        actualRange?.pointee = NSRange(location: offset, length: 0)
        let rect = caretRect(forOffset: offset, width: 2)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return 0 }
        let local = convert(window.convertFromScreen(NSRect(origin: point, size: .zero)).origin, from: nil)
        return offset(at: local)
    }

    /// 取出纯文本(忽略输入法给的富文本属性)。
    private static func plainString(from value: Any) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return (value as? String) ?? ""
    }
}

// MARK: 组合文本写入

extension NativeEditorModel {
    /// 输入法组合文本:把 `range` 替换成 `text`,并按 `selectedInside` 放置光标(相对 `text` 起点)。
    /// 组合过程不进入撤销合并,确认后整体作为一次编辑(靠相同合并键)。
    func replaceForComposition(_ range: TextSpan, with text: String, selectedInside: NSRange) {
        guard isEditable else { return }
        let before = selections.selections
        let units = text.utf16.count
        let inside = NSRange(location: min(max(selectedInside.location, 0), units), length: min(max(selectedInside.length, 0), max(units - selectedInside.location, 0)))
        let caret = Selection(anchor: range.location + inside.location, head: range.location + inside.location + inside.length)
        do {
            try document.apply([DocumentEdit(range: range, text: text)], selectionsBefore: before, selectionsAfter: [caret], coalesceKey: "ime")
        } catch {
            return
        }
        selections = SelectionSet([caret]).clamped(toLength: document.length)
        preferredColumn = nil
        onSelectionChange?()
    }
}
