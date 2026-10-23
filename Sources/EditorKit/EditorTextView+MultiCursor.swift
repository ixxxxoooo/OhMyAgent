// @author ixxxxoooo
// 多光标编辑:多个选区同时键入、退格、回车、Tab、粘贴;一次操作一个撤销步骤,光标各自保持。
// NSTextView 原生在多选区下键入一次后会塌缩成单光标,这里自己把每个选区的编辑合成一次替换。

import AppKit
import DesignSystem

extension EditorTextView {
    /// 选区总数(主选区若干 + 额外空光标)。
    var selectionCount: Int { selectedRanges.count + secondaryCarets.count }

    /// 是否处于可编辑的多光标状态(无输入法组合)。
    var isMultiCursor: Bool {
        isEditable && codeEditingEnabled && !hasMarkedText() && selectionCount > 1
    }

    /// 全部选区(含额外空光标),按位置升序。
    var allSelections: [NSRange] {
        (selectedRanges.map(\.rangeValue) + secondaryCarets.map { NSRange(location: $0, length: 0) })
            .sorted { $0.location < $1.location }
    }

    /// 一次设置全部选区:非空选区与主光标交给 AppKit,其余空光标放进 `secondaryCarets`。
    /// - Parameter ranges: 选区列表(至少一个;越界会被截断)
    func setAllSelections(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }
        let length = (string as NSString).length
        let clamped = ranges.map { range -> NSRange in
            let location = min(max(range.location, 0), length)
            return NSRange(location: location, length: min(range.length, length - location))
        }
        let filled = clamped.filter { $0.length > 0 }
        var empties = clamped.filter { $0.length == 0 }
        let primary: [NSRange]
        if filled.isEmpty, let last = empties.popLast() {
            primary = [last]
        } else {
            primary = filled
        }
        let wasApplying = isApplyingMultiEdit
        isApplyingMultiEdit = true
        super_setSelectedRanges(primary)
        secondaryCarets = empties.map(\.location)
        isApplyingMultiEdit = wasApplying
    }

    /// 直接调用 AppKit 的选区设置(不触发额外光标清空)。
    private func super_setSelectedRanges(_ ranges: [NSRange]) {
        setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
    }

    /// ⌥ 点击:在指定偏移增加一个光标(已存在则移除,方便取消)。
    /// - Parameter offset: UTF-16 偏移
    func addCaret(at offset: Int) {
        var all = allSelections
        if let index = all.firstIndex(where: { $0.length == 0 && $0.location == offset }), all.count > 1 {
            all.remove(at: index)
        } else if !all.contains(where: { NSLocationInRange(offset, $0) && $0.length > 0 }) {
            all.append(NSRange(location: offset, length: 0))
        }
        setAllSelections(all)
    }

    /// 对每个选区各生成一个编辑并一次性应用。
    /// - Parameter make: 由选区(与当前全文)生成编辑;返回 nil 表示该选区保持不动
    /// - Returns: 是否真的修改了文本
    @discardableResult
    func applyMultiEdits(_ make: (NSRange, NSString) -> TextEdit?) -> Bool {
        let ns = string as NSString
        // 重叠或同位置的选区合并
        var merged: [NSRange] = []
        for range in allSelections {
            if let last = merged.last, NSMaxRange(last) > range.location || last.location == range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        let edits = merged.map { range in
            make(range, ns) ?? TextEdit(range: NSRange(location: range.location, length: 0), replacement: "", selection: range)
        }
        let changing = edits.filter { $0.range.length > 0 || !$0.replacement.isEmpty }
        let composed = EditorEditing.compose(edits, in: string)
        isApplyingMultiEdit = true
        defer { isApplyingMultiEdit = false }
        if changing.isEmpty {
            setAllSelections(composed.selections)
            return false
        }
        let ordered = changing.sorted { $0.range.location < $1.range.location }
        guard shouldChangeText(inRanges: ordered.map { NSValue(range: $0.range) }, replacementStrings: ordered.map(\.replacement)),
              let storage = textStorage else { return false }
        storage.beginEditing()
        for edit in ordered.reversed() { storage.replaceCharacters(in: edit.range, with: edit.replacement) }
        storage.endEditing()
        didChangeText()
        setAllSelections(composed.selections)
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// 多光标左右移动:有选区的先收起到边界,空光标按字符移动。
    /// - Parameter step: -1 向左,1 向右
    func multiMove(by step: Int) {
        let ns = string as NSString
        let moved = allSelections.map { range -> NSRange in
            if range.length > 0 { return NSRange(location: step < 0 ? range.location : NSMaxRange(range), length: 0) }
            if step < 0 {
                guard range.location > 0 else { return range }
                return NSRange(location: ns.rangeOfComposedCharacterSequence(at: range.location - 1).location, length: 0)
            }
            guard range.location < ns.length else { return range }
            return NSRange(location: NSMaxRange(ns.rangeOfComposedCharacterSequence(at: range.location)), length: 0)
        }
        // 移动后可能重合,去重
        var seen = Set<Int>()
        setAllSelections(moved.filter { seen.insert($0.location).inserted })
    }

    /// 记录鼠标所在行(行首偏移);鼠标在文本区域之外(最后一行之下)时视为不在任何行上。
    /// - Parameter point: 视图坐标系中的鼠标位置
    func updateHoverNoteLine(at point: NSPoint) {
        guard let layoutManager = textLayoutManager, !string.isEmpty,
              point.y <= (layoutManager.usageBoundsForTextContainer.maxY + textContainerOrigin.y) else {
            hoverNoteLineStart = nil
            return
        }
        let offset = min(characterIndexForInsertion(at: point), (string as NSString).length)
        hoverNoteLineStart = (string as NSString).lineRange(for: NSRange(location: offset, length: 0)).location
    }

    /// 在光标所在行与鼠标悬停行的行尾绘制内联提示(光标行只在单光标、无选区、有焦点时)。
    func drawInlineNote(in dirtyRect: NSRect) {
        guard let inlineNote, let window else { return }
        var offsets: [Int] = []
        if selectionCount == 1, selectedRange().length == 0, window.firstResponder === self {
            offsets.append(selectedRange().location)
        }
        if let hover = hoverNoteLineStart { offsets.append(hover) }
        let ns = string as NSString
        var drawn = Set<Int>()
        for offset in offsets {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: min(offset, ns.length), length: 0))
            guard drawn.insert(lineStart).inserted, let note = inlineNote(lineStart), !note.isEmpty else { continue }
            var actual = NSRange(location: 0, length: 0)
            let screen = firstRect(forCharacterRange: NSRange(location: contentsEnd, length: 0), actualRange: &actual)
            guard screen != .zero else { continue }
            let rect = convert(window.convertFromScreen(screen), from: nil)
            let size = max((font?.pointSize ?? 12) - 1, 9)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(OMColors.tertiaryText),
            ]
            let text = NSAttributedString(string: note, attributes: attributes)
            let textSize = text.size()
            let origin = NSPoint(x: rect.minX + 24, y: rect.minY + (rect.height - textSize.height) / 2)
            if NSRect(origin: origin, size: textSize).intersects(dirtyRect) { text.draw(at: origin) }
        }
    }

    /// 绘制额外的空光标(细竖线,随主题的插入点颜色)。
    func drawSecondaryCarets(in dirtyRect: NSRect) {
        guard !secondaryCarets.isEmpty, window != nil else { return }
        insertionPointColor.setFill()
        for offset in secondaryCarets {
            var actual = NSRange(location: 0, length: 0)
            let screen = firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: &actual)
            guard screen != .zero, let window else { continue }
            let rect = convert(window.convertFromScreen(screen), from: nil)
            let caret = NSRect(x: rect.minX, y: rect.minY, width: 1.5, height: rect.height)
            if caret.intersects(dirtyRect) { caret.fill(using: .sourceOver) }
        }
    }

    /// 多光标输入一段文本(单个括号/引号字符走自动闭合)。
    func multiInsert(_ text: String) {
        let enhance = language != .markdown && language != .plain && EditorBehaviorPrefs.autoClose
        applyMultiEdits { range, _ in
            if enhance, text.count == 1, let char = text.first, let edit = EditorEditing.typed(char, text: string, selection: range) { return edit }
            return TextEdit(range: range, replacement: text, selection: NSRange(location: range.location + (text as NSString).length, length: 0))
        }
    }

    /// 多光标退格:有选区删选区,否则删前一个字符(空括号对一并删除)。
    func multiDeleteBackward() {
        let autoClose = EditorBehaviorPrefs.autoClose
        applyMultiEdits { range, ns in
            if range.length > 0 { return TextEdit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0)) }
            if range.location == 0 { return nil }
            if autoClose, let edit = EditorEditing.backspacePair(text: string, selection: range) { return edit }
            let previous = ns.rangeOfComposedCharacterSequence(at: range.location - 1)
            return TextEdit(range: previous, replacement: "", selection: NSRange(location: previous.location, length: 0))
        }
    }

    /// 多光标向前删除。
    func multiDeleteForward() {
        applyMultiEdits { range, ns in
            if range.length > 0 { return TextEdit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0)) }
            if range.location >= ns.length { return nil }
            let next = ns.rangeOfComposedCharacterSequence(at: range.location)
            return TextEdit(range: next, replacement: "", selection: NSRange(location: range.location, length: 0))
        }
    }

    /// 多光标回车:每处各自保持缩进。
    func multiNewline(unit: String) {
        applyMultiEdits { range, _ in
            let result = EditorEditing.newline(text: string, caret: range.location, unit: unit, language: language)
            return TextEdit(range: range, replacement: result.insertion, selection: NSRange(location: range.location + result.caret, length: 0))
        }
    }

    /// 多光标粘贴:剪贴板行数与光标数相同时一行对一个光标,否则每处粘贴全文。
    func multiPaste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let lines = text.components(separatedBy: "\n")
        let count = selectionCount
        var index = 0
        let distribute = lines.count == count
        applyMultiEdits { range, _ in
            let piece = distribute ? lines[min(index, lines.count - 1)] : text
            index += 1
            return TextEdit(range: range, replacement: piece, selection: NSRange(location: range.location + (piece as NSString).length, length: 0))
        }
    }

    /// Esc:多光标收回为主光标(最后加入的那个)。
    func collapseMultiCursor() {
        let primary = selectedRanges.last?.rangeValue ?? selectedRange()
        setSelectedRange(primary)
    }
}
