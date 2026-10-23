// @author ixxxxoooo
// 原生编辑器的 snippet / Emmet 集成:插入 snippet、Tab/⇧Tab 在占位间跳转、镜像同步、前缀与 Emmet 展开。

import AppKit
import EditorCore

extension NativeEditorModel {
    /// snippet 装饰的 id 起点(避开诊断等其它装饰)。
    private static let snippetDecorationBase = 0x5000_0000

    // MARK: 插入

    /// 插入 snippet。多选区时只作用于主选区。
    /// - Parameters:
    ///   - source: snippet 源文本(VS Code 语法)
    ///   - replacing: 被替换的区间,默认主选区
    ///   - extraVariables: 额外的变量取值
    public func insertSnippet(_ source: String, replacing: TextSpan? = nil, extraVariables: [String: String] = [:]) {
        guard isEditable else { return }
        let rope = document.snapshot
        let range = replacing ?? selections.primary.range
        let line = rope.line(containing: range.location)
        let lead = CursorMotion.leadingWhitespaceLength(ofLine: line, in: rope)
        let indent = rope.string(in: TextSpan(location: rope.lineStart(line), length: min(lead, range.location - rope.lineStart(line))))
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: indentUnit)
            .replacingOccurrences(of: "\n", with: "\n" + indent)
        var variables = snippetVariables(rope: rope, range: range)
        for (key, value) in extraVariables { variables[key] = value }
        let parsed = SnippetParser.parse(normalized, variables: variables)
        let origin = range.location
        let before = selections.selections
        // 先把文本换进文档,再决定占位选区。
        let finalCaret = origin + parsed.text.utf16.count
        do {
            try document.apply([DocumentEdit(range: range, text: parsed.text)], selectionsBefore: before,
                               selectionsAfter: [Selection(caret: finalCaret)])
        } catch {
            return
        }
        expandHistory.removeAll()
        snippetSession = nil
        let placeholders = parsed.stops.filter { $0.index != 0 }
        if placeholders.isEmpty {
            let final = parsed.stops.last?.ranges.first.map { origin + $0.location } ?? finalCaret
            selections = SelectionSet(caret: final).clamped(toLength: document.length)
        } else {
            snippetSession = SnippetSession(snippet: parsed, origin: origin)
            selectCurrentSnippetStop()
        }
        refreshSnippetDecorations()
        preferredColumn = nil
        onSelectionChange?()
    }

    /// 变量表。
    private func snippetVariables(rope: TextRope, range: TextSpan) -> [String: String] {
        var variables: [String: String] = [:]
        if let fileName {
            variables["TM_FILENAME"] = (fileName as NSString).lastPathComponent
            variables["TM_FILENAME_BASE"] = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
            variables["TM_DIRECTORY"] = (fileName as NSString).deletingLastPathComponent
            variables["TM_FILEPATH"] = fileName
        }
        let line = rope.line(containing: range.location)
        variables["TM_SELECTED_TEXT"] = range.isEmpty ? "" : rope.string(in: range)
        variables["TM_CURRENT_LINE"] = rope.lineText(line)
        variables["TM_LINE_INDEX"] = String(line)
        variables["TM_LINE_NUMBER"] = String(line + 1)
        variables["CLIPBOARD"] = NSPasteboard.general.string(forType: .string) ?? ""
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        variables["CURRENT_YEAR"] = String(components.year ?? 0)
        variables["CURRENT_MONTH"] = String(format: "%02d", components.month ?? 0)
        variables["CURRENT_DATE"] = String(format: "%02d", components.day ?? 0)
        variables["CURRENT_HOUR"] = String(format: "%02d", components.hour ?? 0)
        variables["CURRENT_MINUTE"] = String(format: "%02d", components.minute ?? 0)
        variables["CURRENT_SECOND"] = String(format: "%02d", components.second ?? 0)
        return variables
    }

    // MARK: 占位跳转

    /// 选中当前占位的主区间。
    private func selectCurrentSnippetStop() {
        guard let session = snippetSession, let range = session.currentStop.ranges.first else { return }
        selections = SelectionSet([Selection(anchor: range.location, head: range.upperBound)]).clamped(toLength: document.length)
    }

    /// 跳到下一个占位;到达最终位置 `$0` 后会话结束。
    /// - Returns: 是否处理了(没有会话返回 false)
    @discardableResult
    public func nextSnippetStop() -> Bool {
        guard var session = snippetSession else { return false }
        guard session.advance() else { endSnippet(); return true }
        snippetSession = session
        selectCurrentSnippetStop()
        if session.isAtFinalStop { endSnippet(keepSelection: true) } else { refreshSnippetDecorations() }
        preferredColumn = nil
        onSelectionChange?()
        return true
    }

    /// 回到上一个占位。
    @discardableResult
    public func previousSnippetStop() -> Bool {
        guard var session = snippetSession else { return false }
        guard session.retreat() else { return true }
        snippetSession = session
        selectCurrentSnippetStop()
        refreshSnippetDecorations()
        preferredColumn = nil
        onSelectionChange?()
        return true
    }

    /// 结束 snippet 会话并清除占位装饰。
    public func endSnippet(keepSelection: Bool = true) {
        guard snippetSession != nil else { return }
        snippetSession = nil
        refreshSnippetDecorations()
        if !keepSelection { onSelectionChange?() }
    }

    /// 光标离开 snippet 区域时结束会话。
    func validateSnippetSession() {
        guard let session = snippetSession else { return }
        let ranges = session.allRanges.map(\.range)
        guard let lower = ranges.map(\.location).min(), let upper = ranges.map(\.upperBound).max() else { return }
        let head = selections.primary
        if head.range.location < lower || head.range.upperBound > upper {
            snippetSession = nil
            refreshSnippetDecorations()
        }
    }

    /// 同一编号的镜像随正在编辑的占位同步文本。
    func syncSnippetMirrors() {
        guard let session = snippetSession, session.currentStop.ranges.count > 1 else { return }
        let ranges = session.currentStop.ranges
        let head = selections.primary.head
        guard let source = ranges.first(where: { head >= $0.location && head <= $0.upperBound }) else { return }
        let rope = document.snapshot
        let text = rope.string(in: source)
        var edits: [DocumentEdit] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range != source {
            if rope.string(in: range) != text { edits.append(DocumentEdit(range: range, text: text)) }
        }
        guard !edits.isEmpty else { return }
        let before = selections.selections
        let mapped = LineOperations.mapSelections(before, through: edits)
        do {
            try document.apply(edits, selectionsBefore: before, selectionsAfter: mapped, coalesceKey: "typing")
        } catch {
            return
        }
        selections = SelectionSet(mapped, primary: selections.primaryIndex).clamped(toLength: document.length)
        refreshSnippetDecorations()
    }

    /// 重建占位装饰(当前占位更深,其余较浅)。
    func refreshSnippetDecorations() {
        decorations.removeAll { $0.kind == .snippetStop || $0.kind == .snippetStopActive }
        guard let session = snippetSession else { return }
        var id = Self.snippetDecorationBase
        for item in session.allRanges where item.range.length > 0 {
            decorations.insert(Decoration(id: id, range: item.range, kind: item.isCurrent ? .snippetStopActive : .snippetStop,
                                          removesWhenCollapsed: false))
            id += 1
        }
    }

    // MARK: Tab 行为

    /// Tab:占位跳转 → 前缀 snippet → Emmet → 缩进。
    public func tabAction() {
        guard isEditable else { return }
        if nextSnippetStop() { return }
        if selections.selections.count == 1, selections.primary.isEmpty {
            if expandSnippetPrefix() { return }
            if expandEmmet() { return }
        }
        indent()
    }

    /// ⇧Tab:回到上一个占位,否则反缩进。
    public func backtabAction() {
        if previousSnippetStop() { return }
        outdent()
    }

    /// 光标前的单词若是内置 snippet 前缀则展开。
    @discardableResult
    func expandSnippetPrefix() -> Bool {
        let rope = document.snapshot
        let caret = selections.primary.head
        let word = CursorMotion.wordRange(at: max(caret - 1, 0), in: rope)
        guard word.length > 0, word.upperBound == caret else { return false }
        let prefix = rope.string(in: word)
        guard let entry = NativeSnippets.entry(prefix: prefix, language: language) else { return false }
        insertSnippet(entry.body, replacing: word)
        return true
    }

    /// 在 HTML/CSS 中展开光标前的 Emmet 缩写。
    @discardableResult
    func expandEmmet() -> Bool {
        let syntax: Emmet.Syntax
        switch language {
        case .html: syntax = .html
        case .css: syntax = .css
        default: return false
        }
        let rope = document.snapshot
        let caret = selections.primary.head
        let line = rope.line(containing: caret)
        let lineStart = rope.lineStart(line)
        let prefix = rope.string(in: TextSpan(location: lineStart, length: caret - lineStart))
        guard let found = Emmet.abbreviation(in: prefix, syntax: syntax),
              let expanded = Emmet.expand(found.text, syntax: syntax, indentUnit: indentUnit) else { return false }
        insertSnippet(expanded, replacing: TextSpan(lower: lineStart + found.start, upper: caret))
        return true
    }
}
