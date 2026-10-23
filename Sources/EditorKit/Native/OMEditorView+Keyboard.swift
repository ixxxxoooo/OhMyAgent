// @author ixxxxoooo
// 原生编辑视图的键盘与响应者链命令:移动/选择/删除/缩进/撤销/剪贴板。
// 按键经 `interpretKeyEvents` 交给系统键位表(含 Emacs 风格与输入法),再落到 `doCommand(by:)`。

import AppKit
import EditorCore

extension OMEditorView: NSUserInterfaceValidations {
    public override func keyDown(with event: NSEvent) {
        model.document.breakUndoCoalescing()
        // 先交给输入法/键位表;ESC 单独处理(折叠多光标)。
        interpretKeyEvents([event])
    }

    /// 可见视图行数(翻页步长)。
    private var pageRows: Int { max(Int(bounds.height / lineHeight) - 2, 1) }

    // MARK: 命令分派

    public override func doCommand(by selector: Selector) {
        switch selector {
        // 移动
        case #selector(moveLeft(_:)): model.move(.left, extend: false)
        case #selector(moveRight(_:)): model.move(.right, extend: false)
        case #selector(moveUp(_:)): model.move(.up, extend: false)
        case #selector(moveDown(_:)): model.move(.down, extend: false)
        case #selector(moveWordLeft(_:)), #selector(moveWordBackward(_:)): model.move(.wordLeft, extend: false)
        case #selector(moveWordRight(_:)), #selector(moveWordForward(_:)): model.move(.wordRight, extend: false)
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)): model.move(.smartLineStart, extend: false)
        case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)): model.move(.lineEnd, extend: false)
        case #selector(moveToBeginningOfDocument(_:)): model.move(.documentStart, extend: false)
        case #selector(moveToEndOfDocument(_:)): model.move(.documentEnd, extend: false)
        case #selector(moveToBeginningOfParagraph(_:)): model.move(.paragraphUp, extend: false)
        case #selector(moveToEndOfParagraph(_:)): model.move(.paragraphDown, extend: false)
        case #selector(pageUp(_:)): page(up: true, extend: false)
        case #selector(pageDown(_:)): page(up: false, extend: false)
        // 扩展选区
        case #selector(moveLeftAndModifySelection(_:)): model.move(.left, extend: true)
        case #selector(moveRightAndModifySelection(_:)): model.move(.right, extend: true)
        case #selector(moveUpAndModifySelection(_:)): model.move(.up, extend: true)
        case #selector(moveDownAndModifySelection(_:)): model.move(.down, extend: true)
        case #selector(moveWordLeftAndModifySelection(_:)), #selector(moveWordBackwardAndModifySelection(_:)): model.move(.wordLeft, extend: true)
        case #selector(moveWordRightAndModifySelection(_:)), #selector(moveWordForwardAndModifySelection(_:)): model.move(.wordRight, extend: true)
        case #selector(moveToBeginningOfLineAndModifySelection(_:)), #selector(moveToLeftEndOfLineAndModifySelection(_:)): model.move(.smartLineStart, extend: true)
        case #selector(moveToEndOfLineAndModifySelection(_:)), #selector(moveToRightEndOfLineAndModifySelection(_:)): model.move(.lineEnd, extend: true)
        case #selector(moveToBeginningOfDocumentAndModifySelection(_:)): model.move(.documentStart, extend: true)
        case #selector(moveToEndOfDocumentAndModifySelection(_:)): model.move(.documentEnd, extend: true)
        case #selector(moveParagraphBackwardAndModifySelection(_:)): model.move(.paragraphUp, extend: true)
        case #selector(moveParagraphForwardAndModifySelection(_:)): model.move(.paragraphDown, extend: true)
        case #selector(pageUpAndModifySelection(_:)): page(up: true, extend: true)
        case #selector(pageDownAndModifySelection(_:)): page(up: false, extend: true)
        // 滚动
        case #selector(scrollPageUp(_:)): scrollBy(dx: 0, dy: -bounds.height * 0.9)
        case #selector(scrollPageDown(_:)): scrollBy(dx: 0, dy: bounds.height * 0.9)
        case #selector(scrollToBeginningOfDocument(_:)): scroll(y: 0)
        case #selector(scrollToEndOfDocument(_:)): scroll(y: maxScrollY)
        // 删除
        case #selector(deleteBackward(_:)), #selector(deleteBackwardByDecomposingPreviousCharacter(_:)): model.deleteBackward()
        case #selector(deleteForward(_:)): model.deleteForward()
        case #selector(deleteWordBackward(_:)): model.deleteWordBackward()
        case #selector(deleteWordForward(_:)): model.deleteWordForward()
        case #selector(deleteToBeginningOfLine(_:)): model.deleteToLineStart()
        case #selector(deleteToEndOfLine(_:)): model.deleteToLineEnd()
        // 插入
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)): model.insertNewline()
        case #selector(insertTab(_:)): model.indent()
        case #selector(insertBacktab(_:)): model.outdent()
        case #selector(cancelOperation(_:)): escape()
        case #selector(selectAll(_:)): model.selectAll()
        case #selector(selectLine(_:)): model.selectLine()
        default: break
        }
    }

    private func page(up: Bool, extend: Bool) {
        let rows = pageRows
        let before = scrollY
        model.move(up ? .pageUp(rows: rows) : .pageDown(rows: rows), extend: extend)
        // 翻页时视口随光标同步滚动同样的距离,保持光标在屏幕上的相对位置。
        let delta = CGFloat(rows) * lineHeight * (up ? -1 : 1)
        scroll(y: before + delta)
    }

    /// ESC:多光标 → 保留主光标;有选区 → 取消选区。
    private func escape() {
        if model.selections.isMulti {
            model.setSelections(model.selections.collapsedToPrimary())
        } else if !model.selections.primary.isEmpty {
            model.setSelections(SelectionSet(caret: model.selections.primary.head))
        }
    }

    public override func selectLine(_ sender: Any?) { model.selectLine() }
    public override func selectAll(_ sender: Any?) { model.selectAll() }

    // MARK: 响应者链:编辑菜单

    @objc public func undo(_ sender: Any?) { performUndo() }
    @objc public func redo(_ sender: Any?) { performRedo() }

    /// 撤销。
    public func performUndo() {
        guard let restored = model.document.undo() else { return }
        // 模型的 documentDidChange 已处理选区;这里保证光标可见。
        _ = restored
        revealPrimaryCaret()
    }

    /// 重做。
    public func performRedo() {
        guard model.document.redo() != nil else { return }
        revealPrimaryCaret()
    }

    @objc public func copy(_ sender: Any?) {
        guard let text = selectedTextForClipboard() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func cut(_ sender: Any?) {
        guard model.isEditable, let text = selectedTextForClipboard() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.cutSelection()
    }

    @objc public func paste(_ sender: Any?) {
        guard model.isEditable, let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return }
        model.paste(raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }

    /// 剪贴板文本:有选区取选区(多选区以换行连接);全部为空光标时取整行(与 VS Code 一致)。
    func selectedTextForClipboard() -> String? {
        let rope = model.document.snapshot
        let selections = model.selections.selections
        if selections.allSatisfy(\.isEmpty) {
            var seen = Set<Int>()
            var lines: [String] = []
            for selection in selections {
                let line = rope.line(containing: selection.head)
                if seen.insert(line).inserted { lines.append(rope.lineText(line)) }
            }
            return lines.joined(separator: "\n") + "\n"
        }
        return selections.filter { !$0.isEmpty }.map { rope.string(in: $0.range) }.joined(separator: "\n")
    }

    // MARK: 菜单校验

    @objc public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return model.document.canUndo && model.isEditable
        case #selector(redo(_:)): return model.document.canRedo && model.isEditable
        case #selector(cut(_:)): return model.isEditable && !model.selections.primary.isEmpty
        case #selector(copy(_:)): return true
        case #selector(paste(_:)): return model.isEditable
        case #selector(selectAll(_:)), #selector(selectLine(_:)): return true
        default: return false
        }
    }
}
