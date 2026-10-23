// @author ixxxxoooo
// 原生编辑器模型:应用外部给出的一批文本编辑(格式化、LSP 代码操作、重命名)——一次撤销,选区随编辑平移。

import EditorCore
import Foundation

extension NativeEditorModel {
    /// 应用一批编辑(区间基于当前文档,互不重叠;内部会排序并丢弃重叠项)。
    /// - Parameters:
    ///   - edits: 编辑列表
    ///   - coalesceKey: 撤销合并键
    /// - Returns: 是否真的修改了文档
    @discardableResult
    public func applyTextEdits(_ edits: [NativeTextEdit], coalesceKey: String? = nil) -> Bool {
        guard isEditable, !edits.isEmpty else { return false }
        let length = document.length
        var sorted = edits
            .map { NativeTextEdit(range: NSRange(location: min(max($0.range.location, 0), length),
                                                 length: max(min($0.range.length, length - min(max($0.range.location, 0), length)), 0)),
                                  newText: $0.newText) }
            .sorted { $0.range.location < $1.range.location }
        var kept: [NativeTextEdit] = []
        var cursor = 0
        for edit in sorted where edit.range.location >= cursor {
            kept.append(edit)
            cursor = NSMaxRange(edit.range)
        }
        sorted = kept
        let rope = document.snapshot
        // 与原文相同的编辑直接丢弃,避免无意义的撤销步。
        let effective = sorted.filter { rope.string(in: TextSpan(location: $0.range.location, length: $0.range.length)) != $0.newText }
        guard !effective.isEmpty else { return false }
        func shifted(_ offset: Int) -> Int {
            var delta = 0
            for edit in effective {
                if NSMaxRange(edit.range) <= offset { delta += edit.newText.utf16.count - edit.range.length } else if edit.range.location < offset {
                    return edit.range.location + delta + edit.newText.utf16.count
                } else { break }
            }
            return offset + delta
        }
        let before = selections.selections
        let after = before.map { Selection(anchor: shifted($0.anchor), head: shifted($0.head)) }
        let documentEdits = effective.map { DocumentEdit(range: TextSpan(location: $0.range.location, length: $0.range.length), text: $0.newText) }
        do {
            try document.apply(documentEdits, selectionsBefore: before, selectionsAfter: after, coalesceKey: coalesceKey)
        } catch {
            return false
        }
        selections = SelectionSet(after, primary: selections.primaryIndex).clamped(toLength: document.length)
        preferredColumn = nil
        expandHistory.removeAll()
        onSelectionChange?()
        return true
    }
}
