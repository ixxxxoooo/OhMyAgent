// @author ixxxxoooo
// 原生编辑器的编辑命令:输入(含括号/引号自动闭合与跨越、选区环绕)、回车自动缩进、各类删除、缩进与反缩进、剪切复制粘贴文本。
// 全部以「每个选区一个编辑计划」的方式一次性提交给共享文档,多光标与撤销因此天然成立。

import AppKit
import EditorCore

/// 一个选区对应的编辑计划。
struct EditPlan {
    /// 被替换的区间。
    var range: TextSpan
    /// 替换文本。
    var text: String
    /// 编辑后光标相对替换文本起点的 UTF-16 偏移(默认文本末尾)。
    var caretOffset: Int?
    /// 编辑后保留选中的长度(环绕选区时用)。
    var selectLength = 0
    /// 仅移动光标、不改文本时的目标偏移。
    var moveOnly: Int?
}

extension NativeEditorModel {
    // MARK: 计划提交

    /// 提交一批计划:构造编辑与新选区并应用到文档。
    /// - Parameters:
    ///   - plans: 与当前选区一一对应(升序)的计划
    ///   - coalesceKey: 撤销合并键
    /// - Returns: 是否真的修改了文档
    @discardableResult
    func commit(_ plans: [EditPlan], coalesceKey: String? = nil) -> Bool {
        guard isEditable, plans.count == selections.selections.count else { return false }
        var edits: [DocumentEdit] = []
        var after: [Selection] = []
        var delta = 0
        for plan in plans {
            if let target = plan.moveOnly {
                after.append(Selection(caret: target + delta))
                continue
            }
            let units = plan.text.utf16.count
            if !(plan.range.isEmpty && plan.text.isEmpty) { edits.append(DocumentEdit(range: plan.range, text: plan.text)) }
            let start = plan.range.location + delta
            let caret = start + min(max(plan.caretOffset ?? units, 0), units)
            after.append(plan.selectLength > 0 ? Selection(anchor: caret - plan.selectLength, head: caret) : Selection(caret: caret))
            delta += units - plan.range.length
        }
        let before = selections.selections
        if edits.isEmpty {
            setSelections(SelectionSet(after, primary: selections.primaryIndex))
            return false
        }
        do {
            try document.apply(edits, selectionsBefore: before, selectionsAfter: after, coalesceKey: coalesceKey)
        } catch {
            return false
        }
        selections = SelectionSet(after, primary: selections.primaryIndex).clamped(toLength: document.length)
        preferredColumn = nil
        expandHistory.removeAll()
        syncSnippetMirrors()
        onSelectionChange?()
        return true
    }

    // MARK: 输入

    /// 输入文本(已选区被替换)。单字符走括号/引号逻辑。
    public func insertText(_ text: String, replacing replacementRange: TextSpan? = nil) {
        guard isEditable, !text.isEmpty else { return }
        if let replacementRange {
            // 输入法确认:直接替换指定区间。
            let plan = EditPlan(range: replacementRange, text: text)
            if selections.selections.count == 1 { commit([plan]) }
            return
        }
        // 单个换行等同回车,走自动缩进。
        if text == "\n" { insertNewline(); return }
        let rope = document.snapshot
        var plans: [EditPlan] = []
        let single = text.utf16.count == 1 ? text.utf16.first : nil
        for selection in selections.selections {
            let range = selection.range
            if let unit = single, autoClosePairs, let plan = pairPlan(for: unit, range: range, rope: rope) {
                plans.append(plan)
            } else {
                plans.append(EditPlan(range: range, text: text))
            }
        }
        let isTyping = text.utf16.count <= 2 && !text.contains("\n")
        commit(plans, coalesceKey: isTyping ? "typing" : nil)
    }

    /// 括号/引号的自动闭合、跨越与环绕计划;不适用时返回 nil。
    private func pairPlan(for unit: UInt16, range: TextSpan, rope: TextRope) -> EditPlan? {
        guard let scalar = Unicode.Scalar(unit) else { return nil }
        let character = Character(scalar)
        let openers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
        let closers: Set<Character> = [")", "]", "}", "\"", "'", "`"]
        let isQuote = character == "\"" || character == "'" || character == "`"
        // 选区环绕。
        if !range.isEmpty, let closer = openers[character] {
            if isQuote || character == "(" || character == "[" || character == "{" {
                let inner = rope.string(in: range)
                return EditPlan(range: range, text: String(character) + inner + String(closer), caretOffset: inner.utf16.count + 1, selectLength: inner.utf16.count)
            }
        }
        guard range.isEmpty else { return nil }
        let nextUnit = rope.unit(at: range.location)
        // 跨越已有的闭合符。
        if closers.contains(character), let nextUnit, nextUnit == unit {
            return EditPlan(range: range, text: "", moveOnly: range.location + 1)
        }
        guard let closer = openers[character] else { return nil }
        // 仅当后面是空白/行尾/闭合符时才自动补全。
        let nextAllowsPair: Bool = {
            guard let nextUnit else { return true }
            guard let next = Unicode.Scalar(nextUnit) else { return false }
            let ch = Character(next)
            return ch == " " || ch == "\t" || ch == "\n" || ")]};,>:".contains(ch)
        }()
        guard nextAllowsPair else { return nil }
        if isQuote, range.location > 0, let previous = rope.unit(at: range.location - 1), let prevScalar = Unicode.Scalar(previous) {
            // 单词字符之后的引号(如 don't)不补全。
            if CursorMotion.classify(prevScalar.value) == .word { return nil }
        }
        return EditPlan(range: range, text: String(character) + String(closer), caretOffset: 1)
    }

    // MARK: 回车

    /// 回车:沿用当前行缩进,`{`/`(`/`[`/`:` 后多缩一级,括号之间拆成三行。
    public func insertNewline() {
        guard isEditable else { return }
        let rope = document.snapshot
        var plans: [EditPlan] = []
        for selection in selections.selections {
            let range = selection.range
            let line = rope.line(containing: range.location)
            let lineStart = rope.lineStart(line)
            let leading = CursorMotion.leadingWhitespaceLength(ofLine: line, in: rope)
            let indentLength = min(leading, range.location - lineStart)
            let indent = rope.string(in: TextSpan(location: lineStart, length: indentLength))
            let before = range.location > 0 ? rope.unit(at: range.location - 1) : nil
            let after = rope.unit(at: range.upperBound)
            let opener = before.flatMap { Unicode.Scalar($0) }.map(Character.init)
            let closer = after.flatMap { Unicode.Scalar($0) }.map(Character.init)
            let pairs: [Character: Character] = ["{": "}", "(": ")", "[": "]"]
            let wantsExtra = (opener.map { pairs[$0] != nil } ?? false) || (language == .python && opener == ":")
            if let opener, let closer, pairs[opener] == closer {
                let inner = indent + indentUnit
                let text = "\n" + inner + "\n" + indent
                plans.append(EditPlan(range: range, text: text, caretOffset: 1 + inner.utf16.count))
            } else {
                plans.append(EditPlan(range: range, text: "\n" + indent + (wantsExtra ? indentUnit : "")))
            }
        }
        commit(plans)
    }

    // MARK: 删除

    /// 向后删除一个字符(空选区)或删除选区;括号对一并删除,缩进内按制表位回退。
    public func deleteBackward() {
        guard isEditable else { return }
        let rope = document.snapshot
        var plans: [EditPlan] = []
        for selection in selections.selections {
            let range = selection.range
            if !range.isEmpty { plans.append(EditPlan(range: range, text: "")); continue }
            let offset = range.location
            if offset == 0 { plans.append(EditPlan(range: range, text: "", moveOnly: 0)); continue }
            if autoClosePairs, let before = rope.unit(at: offset - 1), let after = rope.unit(at: offset), Self.isPair(before, after) {
                plans.append(EditPlan(range: TextSpan(location: offset - 1, length: 2), text: ""))
                continue
            }
            let line = rope.line(containing: offset)
            let lineStart = rope.lineStart(line)
            let column = offset - lineStart
            let unitWidth = indentUnit.first == " " ? indentUnit.utf16.count : 0
            if unitWidth > 0, column > 0, CursorMotion.leadingWhitespaceLength(ofLine: line, in: rope) >= column,
               rope.slice(TextSpan(location: lineStart, length: column)).allSatisfy({ $0 == 0x20 }) {
                let stop = ((column - 1) / unitWidth) * unitWidth
                plans.append(EditPlan(range: TextSpan(location: lineStart + stop, length: column - stop), text: ""))
                continue
            }
            let previous = CursorMotion.previousCharacter(offset, in: rope)
            plans.append(EditPlan(range: TextSpan(lower: previous, upper: offset), text: ""))
        }
        commit(plans, coalesceKey: "delete")
    }

    /// 向前删除一个字符或选区。
    public func deleteForward() {
        guard isEditable else { return }
        let rope = document.snapshot
        let plans = selections.selections.map { selection -> EditPlan in
            let range = selection.range
            if !range.isEmpty { return EditPlan(range: range, text: "") }
            let next = CursorMotion.nextCharacter(range.location, in: rope)
            return EditPlan(range: TextSpan(lower: range.location, upper: next), text: "")
        }
        commit(plans, coalesceKey: "delete")
    }

    /// 按词向后删除。
    public func deleteWordBackward() {
        guard isEditable else { return }
        let rope = document.snapshot
        let plans = selections.selections.map { selection -> EditPlan in
            let range = selection.range
            if !range.isEmpty { return EditPlan(range: range, text: "") }
            return EditPlan(range: TextSpan(lower: CursorMotion.previousWordStart(range.location, in: rope), upper: range.location), text: "")
        }
        commit(plans)
    }

    /// 按词向前删除。
    public func deleteWordForward() {
        guard isEditable else { return }
        let rope = document.snapshot
        let plans = selections.selections.map { selection -> EditPlan in
            let range = selection.range
            if !range.isEmpty { return EditPlan(range: range, text: "") }
            return EditPlan(range: TextSpan(lower: range.location, upper: CursorMotion.nextWordEnd(range.location, in: rope)), text: "")
        }
        commit(plans)
    }

    /// 删到行首(⌘⌫)。
    public func deleteToLineStart() {
        guard isEditable else { return }
        let rope = document.snapshot
        let plans = selections.selections.map { selection -> EditPlan in
            let range = selection.range
            if !range.isEmpty { return EditPlan(range: range, text: "") }
            let lineStart = CursorMotion.lineStart(from: range.location, in: rope)
            let target = range.location == lineStart ? max(range.location - 1, 0) : lineStart
            return EditPlan(range: TextSpan(lower: target, upper: range.location), text: "")
        }
        commit(plans)
    }

    /// 删到行尾(⌃K)。
    public func deleteToLineEnd() {
        guard isEditable else { return }
        let rope = document.snapshot
        let plans = selections.selections.map { selection -> EditPlan in
            let range = selection.range
            if !range.isEmpty { return EditPlan(range: range, text: "") }
            let end = CursorMotion.lineEnd(from: range.location, in: rope)
            let target = range.location == end ? min(end + 1, rope.length) : end
            return EditPlan(range: TextSpan(lower: range.location, upper: target), text: "")
        }
        commit(plans)
    }

    /// 是否为一对括号/引号(用于成对删除)。
    static func isPair(_ open: UInt16, _ close: UInt16) -> Bool {
        switch (open, close) {
        case (0x28, 0x29), (0x5B, 0x5D), (0x7B, 0x7D), (0x22, 0x22), (0x27, 0x27), (0x60, 0x60): true
        default: false
        }
    }

    // MARK: 缩进

    /// Tab:多行选区整体缩进,否则插入缩进单位(空格缩进补到下一个制表位)。
    public func indent() {
        guard isEditable else { return }
        let rope = document.snapshot
        let multiline = selections.selections.contains { rope.line(containing: $0.range.location) != rope.line(containing: $0.range.upperBound) }
        if multiline { shiftLines(outdent: false); return }
        let plans = selections.selections.map { selection -> EditPlan in
            let range = selection.range
            if indentUnit == "\t" { return EditPlan(range: range, text: "\t") }
            let width = indentUnit.utf16.count
            let column = range.location - rope.lineStart(rope.line(containing: range.location))
            let pad = width - (column % width)
            return EditPlan(range: range, text: String(repeating: " ", count: pad))
        }
        commit(plans)
    }

    /// ⇧Tab:反缩进选中的行(无选区时反缩进当前行)。
    public func outdent() { shiftLines(outdent: true) }

    /// 整行缩进/反缩进:对选区覆盖的每一行首插入或移除一个缩进单位。
    func shiftLines(outdent: Bool) {
        guard isEditable else { return }
        let rope = document.snapshot
        var handled = Set<Int>()
        var edits: [DocumentEdit] = []
        for selection in selections.selections {
            let range = selection.range
            let first = rope.line(containing: range.location)
            var last = rope.line(containing: range.upperBound)
            // 选区末端恰好在下一行行首时不包含该行。
            if last > first, range.upperBound == rope.lineStart(last), !range.isEmpty { last -= 1 }
            for line in first...last where handled.insert(line).inserted {
                let start = rope.lineStart(line)
                if outdent {
                    let lead = CursorMotion.leadingWhitespaceLength(ofLine: line, in: rope)
                    guard lead > 0 else { continue }
                    let remove: Int
                    if rope.unit(at: start) == 9 { remove = 1 } else { remove = min(lead, max(indentUnit.utf16.count, 1)) }
                    edits.append(DocumentEdit(range: TextSpan(location: start, length: remove), text: ""))
                } else if rope.lineLength(line) > 0 {
                    edits.append(DocumentEdit(range: TextSpan(location: start, length: 0), text: indentUnit))
                }
            }
        }
        guard !edits.isEmpty else { return }
        let before = selections.selections
        let change: DocumentChange?
        do { change = try document.apply(edits, selectionsBefore: before, selectionsAfter: before) } catch { return }
        // 选区随编辑平移,保持覆盖原来的行。
        if let change { selections = selections.mapped(through: change.edits).clamped(toLength: document.length) }
        onSelectionChange?()
    }
}

// MARK: 剪贴板

extension NativeEditorModel {
    /// 剪切:有选区删除选区;全是空光标时删除所在整行。
    public func cutSelection() {
        guard isEditable else { return }
        let rope = document.snapshot
        if selections.selections.allSatisfy(\.isEmpty) {
            var handled = Set<Int>()
            var plans: [EditPlan] = []
            for selection in selections.selections {
                let line = rope.line(containing: selection.head)
                let start = rope.lineStart(line)
                guard handled.insert(line).inserted else {
                    plans.append(EditPlan(range: TextSpan(location: start, length: 0), text: ""))
                    continue
                }
                let end = line + 1 < rope.lineCount ? rope.lineStart(line + 1) : rope.length
                // 末行没有换行符时连同前一个换行一起删除,避免留下空行。
                let from = (end == rope.length && line > 0 && end > start) ? start - 1 : start
                plans.append(EditPlan(range: TextSpan(lower: from, upper: end), text: ""))
            }
            commit(plans)
        } else {
            commit(selections.selections.filter { !$0.isEmpty }.map { EditPlan(range: $0.range, text: "") })
        }
    }

    /// 粘贴:光标数与剪贴板行数相同时逐行分配,否则每个光标粘贴全部文本。
    /// - Parameter text: 已规范化换行为 `\n` 的文本
    public func paste(_ text: String) {
        guard isEditable, !text.isEmpty else { return }
        let count = selections.selections.count
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if count > 1, lines.count == count {
            let plans = zip(selections.selections, lines).map { EditPlan(range: $0.range, text: $1) }
            commit(plans)
        } else {
            let plans = selections.selections.map { EditPlan(range: $0.range, text: text) }
            commit(plans)
        }
    }
}
