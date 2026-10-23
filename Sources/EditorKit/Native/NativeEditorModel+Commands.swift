// @author ixxxxoooo
// 原生编辑器的高级编辑命令:行操作(移动/复制/删除/合并/插入)、注释切换、排序与大小写、
// 多光标(上下加光标、选中下一个/全部相同项、按行拆分)、扩大/缩小选择。
// 纯计算在 `EditorCore.LineOperations`/`TextSearch`,这里负责提交为单个撤销步骤并更新选区。

import AppKit
import EditorCore

extension NativeEditorModel {
    // MARK: 提交

    /// 把命令产出作为一个撤销步骤应用到文档,并设置新选区。
    /// - Returns: 是否修改了文档
    @discardableResult
    func commit(_ outcome: EditOutcome?, coalesceKey: String? = nil) -> Bool {
        guard isEditable, let outcome else { return false }
        let before = selections.selections
        do {
            try document.apply(outcome.edits, selectionsBefore: before, selectionsAfter: outcome.selections, coalesceKey: coalesceKey)
        } catch {
            return false
        }
        selections = SelectionSet(outcome.selections, primary: min(selections.primaryIndex, outcome.selections.count - 1))
            .clamped(toLength: document.length)
        preferredColumn = nil
        expandHistory.removeAll()
        syncSnippetMirrors()
        onSelectionChange?()
        return true
    }

    // MARK: 行操作

    /// 上移/下移选中行(⌥↑/⌥↓)。
    public func moveLines(up: Bool) {
        commit(LineOperations.moveLines(rope: document.snapshot, selections: selections.selections, up: up))
    }

    /// 向上/向下复制选中行(⌥⇧↑/⌥⇧↓)。
    public func duplicateLines(down: Bool) {
        commit(LineOperations.duplicateLines(rope: document.snapshot, selections: selections.selections, down: down))
    }

    /// 删除选中行(⌘⇧K)。
    public func deleteLines() {
        commit(LineOperations.deleteLines(rope: document.snapshot, selections: selections.selections))
    }

    /// 合并行(⌃J)。
    public func joinLines() {
        commit(LineOperations.joinLines(rope: document.snapshot, selections: selections.selections))
    }

    /// 在下方/上方插入新行(⌘↩ / ⌘⇧↩)。
    public func insertLine(below: Bool) {
        commit(LineOperations.insertLine(rope: document.snapshot, selections: selections.selections, below: below, indentUnit: indentUnit))
    }

    /// 切换行注释(⌘/)。
    public func toggleLineComment() {
        guard let prefix = EditorEditing.commentPrefix(for: language) else { toggleBlockComment(); return }
        commit(LineOperations.toggleLineComment(rope: document.snapshot, selections: selections.selections, prefix: prefix))
    }

    /// 切换块注释(⌥⇧A)。
    public func toggleBlockComment() {
        guard let tokens = Self.blockCommentTokens(for: language) else { return }
        commit(LineOperations.toggleBlockComment(rope: document.snapshot, selections: selections.selections, open: tokens.open, close: tokens.close))
    }

    /// 语言的块注释符号。
    static func blockCommentTokens(for language: SyntaxLanguage) -> (open: String, close: String)? {
        switch language {
        case .swift, .javascript, .typescript, .rust, .go, .java, .c, .php, .css, .sql: return ("/*", "*/")
        case .html, .markdown: return ("<!--", "-->")
        case .lua: return ("--[[", "]]")
        default: return nil
        }
    }

    /// 排序选中行(无选区时排序全文)。
    public func sortLines(descending: Bool = false) {
        commit(LineOperations.sortLines(rope: document.snapshot, selections: selections.selections, descending: descending))
    }

    /// 转换大小写。
    public func transformCase(_ transform: LineOperations.CaseTransform) {
        commit(LineOperations.transformCase(rope: document.snapshot, selections: selections.selections, transform: transform))
    }

    /// 去除全文行尾空白。
    public func trimTrailingWhitespace() {
        commit(LineOperations.trimTrailingWhitespace(rope: document.snapshot, selections: selections.selections))
    }

    // MARK: 多光标

    /// 在上方/下方加一个光标(⌥⌘↑/⌥⌘↓)。
    public func addCursor(above: Bool) {
        var list = selections.selections
        let saved = preferredColumn
        for selection in selections.selections {
            let target = verticalTarget(from: selection.head, delta: above ? -1 : 1)
            preferredColumn = saved ?? preferredColumn
            if target != selection.head, !list.contains(where: { $0.isEmpty && $0.head == target }) { list.append(Selection(caret: target)) }
        }
        guard list.count > selections.selections.count else { return }
        let column = preferredColumn
        setSelections(SelectionSet(list), keepPreferredColumn: true)
        preferredColumn = column
    }

    /// 选中下一个相同项(⌘D):空光标先选中所在单词;之后把下一处(到末尾后回绕)加入选区。
    /// - Returns: 新增选区的范围,供视图滚动到可见;没有可加入的返回 nil
    @discardableResult
    public func selectNextOccurrence() -> TextSpan? {
        let rope = document.snapshot
        let primary = selections.primary
        if primary.isEmpty {
            let word = CursorMotion.wordRange(at: primary.head, in: rope)
            guard word.length > 0 else { return nil }
            setSelections(SelectionSet([Selection(anchor: word.location, head: word.upperBound)]))
            return word
        }
        guard primary.range.length <= 10_000 else { return nil }
        let needle = rope.string(in: primary.range)
        let existing = Set(selections.selections.map(\.range.location))
        var from = selections.selections.map(\.range.upperBound).max() ?? primary.range.upperBound
        for _ in 0..<2 {
            guard let hit = TextSearch.next(in: rope, pattern: needle, options: SearchOptions(caseSensitive: true), from: from, wrap: false) else {
                from = 0
                continue
            }
            if existing.contains(hit.location) { return nil }
            setSelections(selections.adding(Selection(anchor: hit.location, head: hit.upperBound)))
            return hit
        }
        return nil
    }

    /// 选中全部相同项(⌘F2)。
    public func selectAllOccurrences() {
        let rope = document.snapshot
        let primary = selections.primary
        var needleRange = primary.range
        if primary.isEmpty { needleRange = CursorMotion.wordRange(at: primary.head, in: rope) }
        guard needleRange.length > 0, needleRange.length <= 10_000 else { return }
        let needle = rope.string(in: needleRange)
        let hits = TextSearch.matches(in: rope, pattern: needle, options: SearchOptions(caseSensitive: true), limit: 10_000)
        guard !hits.isEmpty else { return }
        let primaryIndex = hits.firstIndex { $0.location == needleRange.location } ?? 0
        setSelections(SelectionSet(hits.map { Selection(anchor: $0.location, head: $0.upperBound) }, primary: primaryIndex))
    }

    /// 把多行选区拆成每行末尾一个光标(⌥⇧I)。
    public func splitSelectionIntoLines() {
        let rope = document.snapshot
        var list: [Selection] = []
        for selection in selections.selections {
            guard !selection.isEmpty else { list.append(selection); continue }
            let range = selection.range
            let first = rope.line(containing: range.location)
            var last = rope.line(containing: range.upperBound)
            if last > first, range.upperBound == rope.lineStart(last) { last -= 1 }
            for line in first...last {
                let end = min(rope.lineStart(line) + rope.lineLength(line), range.upperBound)
                list.append(Selection(caret: end))
            }
        }
        setSelections(SelectionSet(list))
    }

    // MARK: 扩大 / 缩小选择

    /// 扩大选择(⌃⇧⌘→):光标 → 单词 → 行内容 → 整行 → 外层括号内 → 外层括号含括号 → … → 全文。
    public func expandSelection() {
        let rope = document.snapshot
        let current = selections.primary.range
        let next = Self.expandedRange(from: current, in: rope)
        guard next != current else { return }
        expandHistory.append(selections)
        let reversed = selections.primary.isReversed
        let selection = reversed ? Selection(anchor: next.upperBound, head: next.location) : Selection(anchor: next.location, head: next.upperBound)
        let history = expandHistory
        setSelections(SelectionSet([selection]))
        expandHistory = history
    }

    /// 缩小选择(⌃⇧⌘←):回到上一次扩大前的选区。
    public func shrinkSelection() {
        guard let previous = expandHistory.popLast() else { return }
        let history = expandHistory
        setSelections(previous)
        expandHistory = history
    }

    /// 计算比 `range` 更大的下一级语法范围。
    static func expandedRange(from range: TextSpan, in rope: TextRope) -> TextSpan {
        var candidates: [TextSpan] = []
        let word = CursorMotion.wordRange(at: range.location, in: rope)
        if word.length > 0 { candidates.append(word) }
        let first = rope.line(containing: range.location)
        let last = rope.line(containing: range.upperBound)
        let lead = CursorMotion.leadingWhitespaceLength(ofLine: first, in: rope)
        let contentStart = rope.lineStart(first) + lead
        let contentEnd = rope.lineStart(last) + rope.lineLength(last)
        if contentStart < contentEnd { candidates.append(TextSpan(lower: contentStart, upper: contentEnd)) }
        candidates.append(TextSpan(lower: rope.lineStart(first), upper: last + 1 < rope.lineCount ? rope.lineStart(last + 1) : rope.length))
        var probe = range
        for _ in 0..<64 {
            guard let pair = enclosingPair(of: probe, in: rope) else { break }
            candidates.append(TextSpan(lower: pair.open + 1, upper: pair.close))
            candidates.append(TextSpan(lower: pair.open, upper: pair.close + 1))
            probe = TextSpan(lower: pair.open, upper: pair.close + 1)
        }
        candidates.append(TextSpan(location: 0, length: rope.length))
        // 取包住当前选区的最小候选。
        return candidates
            .filter { $0.location <= range.location && $0.upperBound >= range.upperBound && $0.length > range.length }
            .min { $0.length < $1.length } ?? range
    }

    /// 包住 `range` 的最内层括号对(向两侧各扫描至多 200K 单位)。
    static func enclosingPair(of range: TextSpan, in rope: TextRope) -> (open: Int, close: Int)? {
        let limit = 200_000
        let pairs: [UInt16: UInt16] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
        let closers: [UInt16: UInt16] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]
        var stack: [UInt16] = []
        var open = range.location - 1
        let lowest = max(0, range.location - limit)
        var foundOpen: Int?
        while open >= lowest {
            guard let unit = rope.unit(at: open) else { break }
            if closers[unit] != nil { stack.append(unit) }
            else if pairs[unit] != nil {
                if let top = stack.last, closers[top] == unit { stack.removeLast() } else { foundOpen = open; break }
            }
            open -= 1
        }
        guard let start = foundOpen, let openUnit = rope.unit(at: start), let wanted = pairs[openUnit] else { return nil }
        var depth = 0
        var position = range.upperBound
        let highest = min(rope.length, range.upperBound + limit)
        while position < highest {
            guard let unit = rope.unit(at: position) else { break }
            if unit == openUnit { depth += 1 }
            else if unit == wanted {
                if depth == 0 { return (start, position) }
                depth -= 1
            }
            position += 1
        }
        return nil
    }
}
