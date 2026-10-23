// @author ixxxxoooo
// 原生编辑器的光标移动与选择:字符/单词/行/文档/段落/翻页,垂直移动按视图行(软换行)并记住偏好列。

import AppKit
import EditorCore

/// 光标移动种类。
public enum CaretMotion: Sendable {
    case left, right, up, down
    case wordLeft, wordRight
    case lineStart, lineEnd, smartLineStart
    case documentStart, documentEnd
    case pageUp(rows: Int), pageDown(rows: Int)
    case paragraphUp, paragraphDown
}

extension NativeEditorModel {
    /// 移动所有光标。
    /// - Parameters:
    ///   - motion: 移动种类
    ///   - extend: 是否扩展选区(按住 ⇧)
    public func move(_ motion: CaretMotion, extend: Bool) {
        let rope = document.snapshot
        var keepColumn = false
        let next = selections.selections.map { selection -> Selection in
            let range = selection.range
            var head = selection.head
            // 不扩展时,左右键在有选区的情况下先折叠到边缘。
            if !extend, !selection.isEmpty {
                switch motion {
                case .left: return Selection(caret: range.location)
                case .right: return Selection(caret: range.upperBound)
                default: break
                }
            }
            switch motion {
            case .left: head = CursorMotion.previousCharacter(head, in: rope)
            case .right: head = CursorMotion.nextCharacter(head, in: rope)
            case .wordLeft: head = CursorMotion.previousWordStart(head, in: rope)
            case .wordRight: head = CursorMotion.nextWordEnd(head, in: rope)
            case .lineStart: head = visualRowStart(of: head)
            case .smartLineStart: head = CursorMotion.smartLineStart(from: head, in: rope)
            case .lineEnd: head = visualRowEnd(of: head)
            case .documentStart: head = 0
            case .documentEnd: head = rope.length
            case .up: head = verticalTarget(from: head, delta: -1); keepColumn = true
            case .down: head = verticalTarget(from: head, delta: 1); keepColumn = true
            case .pageUp(let rows): head = verticalTarget(from: head, delta: -max(rows, 1)); keepColumn = true
            case .pageDown(let rows): head = verticalTarget(from: head, delta: max(rows, 1)); keepColumn = true
            case .paragraphUp: head = paragraphTarget(from: head, forward: false)
            case .paragraphDown: head = paragraphTarget(from: head, forward: true)
            }
            return extend ? Selection(anchor: selection.anchor, head: head) : Selection(caret: head)
        }
        let column = preferredColumn
        setSelections(SelectionSet(next, primary: selections.primaryIndex), keepPreferredColumn: keepColumn)
        if keepColumn { preferredColumn = column ?? preferredColumn }
    }

    /// 全选。
    public func selectAll() {
        setSelections(SelectionSet([Selection(anchor: 0, head: document.length)]))
    }

    /// 选中光标所在的整行(可连续扩展)。
    public func selectLine() {
        let rope = document.snapshot
        let next = selections.selections.map { selection -> Selection in
            let range = selection.range
            let first = rope.line(containing: range.location)
            let last = rope.line(containing: range.upperBound)
            let start = rope.lineStart(first)
            let end = last + 1 < rope.lineCount ? rope.lineStart(last + 1) : rope.length
            return Selection(anchor: start, head: end)
        }
        setSelections(SelectionSet(next))
    }

    // MARK: 视觉行

    /// 所在视图行的起点(换行行首);折叠隐藏的位置返回原值。
    func visualRowStart(of offset: Int) -> Int {
        let row = viewRow(ofOffset: offset)
        let span = rowSpan(ofRow: row)
        return document.snapshot.lineStart(span.line) + span.start
    }

    /// 所在视图行的终点。
    func visualRowEnd(of offset: Int) -> Int {
        let row = viewRow(ofOffset: offset)
        let span = rowSpan(ofRow: row)
        let start = document.snapshot.lineStart(span.line)
        // 续行末尾停在换行点之前,避免光标跳到下一行行首。
        return start + span.end
    }

    /// 垂直移动 `delta` 个视图行后的目标偏移,保持偏好视觉列。
    func verticalTarget(from offset: Int, delta: Int) -> Int {
        let rope = document.snapshot
        let currentRow = viewRow(ofOffset: offset)
        let span = rowSpan(ofRow: currentRow)
        let lineStart = rope.lineStart(span.line)
        let units = rope.slice(TextSpan(location: lineStart + span.start, length: span.end - span.start))
        if preferredColumn == nil {
            preferredColumn = metrics.column(inLine: units, atOffset: min(offset - lineStart - span.start, units.count))
        }
        let total = lineMap.totalRows
        let targetRow = currentRow + delta
        if targetRow < 0 { return 0 }
        if targetRow >= total { return rope.length }
        let target = rowSpan(ofRow: targetRow)
        let targetStart = rope.lineStart(target.line)
        let targetUnits = rope.slice(TextSpan(location: targetStart + target.start, length: target.end - target.start))
        let column = metrics.offset(inLine: targetUnits, atColumn: preferredColumn ?? 0)
        return targetStart + target.start + column
    }

    /// 段落移动:跳到上/下一个空行。
    private func paragraphTarget(from offset: Int, forward: Bool) -> Int {
        let rope = document.snapshot
        var line = rope.line(containing: offset)
        let step = forward ? 1 : -1
        // 先越过当前所在的空行,再找下一个空行。
        while line + step >= 0, line + step < rope.lineCount, rope.lineLength(line) == 0 { line += step }
        while line + step >= 0, line + step < rope.lineCount {
            line += step
            if rope.lineLength(line) == 0 { return rope.lineStart(line) }
        }
        return forward ? rope.length : 0
    }
}
