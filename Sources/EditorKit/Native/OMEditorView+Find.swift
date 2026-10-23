// @author ixxxxoooo
// 原生编辑视图的查找/替换:复用 `EditorFindBar` 悬浮条,搜索走 rope 上的 `TextSearch`(大文档后台分窗口),
// 匹配以装饰呈现(查找命中/当前命中,同时进入概览尺),替换整体作为一个撤销步骤。

import AppKit
import DesignSystem
import EditorCore
import SwiftUI

extension OMEditorView {
    /// 小于该长度的文档同步搜索(输入时即时反馈),更大的放后台。
    private static let syncSearchLimit = 400_000

    // MARK: 活动编辑器

    /// 当前应响应查找命令的原生编辑器:键盘焦点所在,否则最近聚焦且仍可见的。
    public static func activeEditor() -> OMEditorView? {
        var view = NSApp.keyWindow?.firstResponder as? NSView
        while let current = view {
            if let editor = current as? OMEditorView { return editor }
            view = current.superview
        }
        if let editor = lastFocused, editor.window != nil, !editor.isHiddenOrHasHiddenAncestor { return editor }
        return nil
    }

    // MARK: 显示与关闭

    /// 打开(或聚焦)查找条;有单行选区时用它作为查询词。
    /// - Parameter replace: 是否展开替换行
    public func showFind(replace: Bool = false) {
        findModel.isEditable = model.isEditable
        if replace, model.isEditable { findModel.showsReplace = true }
        let primary = model.selections.primary.range
        if primary.length > 0, primary.length < 200 {
            let text = model.document.snapshot.string(in: primary)
            if !text.contains("\n") { findModel.query = text }
        }
        if findHost == nil {
            findModel.onSearchChange = { [weak self] in self?.refreshFind(jump: true) }
            findModel.onNext = { [weak self] in self?.findStep(forward: true) }
            findModel.onPrevious = { [weak self] in self?.findStep(forward: false) }
            findModel.onReplace = { [weak self] in self?.replaceCurrent() }
            findModel.onReplaceAll = { [weak self] in self?.replaceAllMatches() }
            findModel.onClose = { [weak self] in self?.hideFind() }
            let host = NSHostingView(rootView: EditorFindBar(model: findModel))
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: topAnchor, constant: -4),
                host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -rightInset),
            ])
            findHost = host
        }
        findModel.focusToken += 1
        refreshFind(jump: true)
    }

    /// 关闭查找条并清除命中装饰,焦点回到文本区。
    public func hideFind() {
        findTask?.cancel()
        findGeneration += 1
        findMatches = []
        applyFindDecorations()
        findHost?.removeFromSuperview()
        findHost = nil
        window?.makeFirstResponder(self)
    }

    /// 设置查询词(调试钩子与命令入口使用)。
    public func setFindQuery(_ query: String) { findModel.query = query }

    /// 查找条是否打开。
    public var isFindVisible: Bool { findHost != nil }

    // MARK: 搜索

    private var findOptions: SearchOptions {
        SearchOptions(caseSensitive: findModel.options.caseSensitive, wholeWord: findModel.options.wholeWord, regex: findModel.options.regex)
    }

    /// 重新搜索。
    /// - Parameter jump: 是否跳到离光标最近的匹配并选中
    func refreshFind(jump: Bool) {
        guard findHost != nil else { return }
        findTask?.cancel()
        findGeneration += 1
        let generation = findGeneration
        let pattern = findModel.query
        let options = findOptions
        findModel.isInvalidPattern = !pattern.isEmpty && TextSearch.compile(pattern, options: options) == nil
        guard !pattern.isEmpty, !findModel.isInvalidPattern else {
            findMatches = []
            findModel.matchCount = 0
            findModel.currentIndex = nil
            applyFindDecorations()
            return
        }
        let rope = model.document.snapshot
        let limit = EditorFindEngine.maxMatches
        if rope.length <= Self.syncSearchLimit {
            finishFind(TextSearch.matches(in: rope, pattern: pattern, options: options, limit: limit), jump: jump)
            return
        }
        findTask = Task { [weak self] in
            let matches = await Task.detached(priority: .userInitiated) {
                TextSearch.matches(in: rope, pattern: pattern, options: options, limit: limit)
            }.value
            guard !Task.isCancelled, let self, generation == self.findGeneration else { return }
            self.finishFind(matches, jump: jump)
        }
    }

    /// 搜索完成:记录结果、选中最近一处、刷新装饰。
    private func finishFind(_ matches: [TextSpan], jump: Bool) {
        findMatches = matches
        findModel.matchCount = matches.count
        let head = model.selections.primary.range.location
        let index = matches.firstIndex { $0.location >= head } ?? (matches.isEmpty ? nil : 0)
        if jump, let index {
            selectFindMatch(index)
        } else {
            findModel.currentIndex = matches.isEmpty ? nil : min(findModel.currentIndex ?? 0, matches.count - 1)
            applyFindDecorations()
        }
    }

    /// 文本被编辑后的防抖刷新(保持当前位置,不抢选区)。
    func scheduleFindRefresh() {
        findTask?.cancel()
        findGeneration += 1
        let generation = findGeneration
        findTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, generation == self.findGeneration else { return }
            self.refreshFind(jump: false)
        }
    }

    /// 跳到下一个/上一个匹配。
    /// - Parameter forward: 方向
    public func findStep(forward: Bool) {
        guard !findMatches.isEmpty else { return }
        let range = model.selections.primary.range
        let index: Int
        if forward {
            index = findMatches.firstIndex { $0.location >= range.upperBound } ?? 0
        } else {
            index = findMatches.lastIndex { $0.location < range.location } ?? findMatches.count - 1
        }
        selectFindMatch(index)
    }

    /// 选中并滚动到某个匹配。
    private func selectFindMatch(_ index: Int) {
        guard findMatches.indices.contains(index) else { return }
        let span = findMatches[index]
        findModel.currentIndex = index
        model.setSelections(SelectionSet([Selection(anchor: span.location, head: span.upperBound)]))
        applyFindDecorations()
    }

    /// 把命中写入装饰(当前命中单独着色)。
    private func applyFindDecorations() {
        let current = findModel.currentIndex
        let base = 0x6000_0000
        let items = findMatches.enumerated().map { index, span in
            Decoration(id: base + index, range: span, kind: index == current ? .findCurrent : .findMatch, removesWhenCollapsed: true)
        }
        model.decorations.replace(kinds: [.findMatch, .findCurrent], with: items)
        needsDisplay = true
    }

    // MARK: 替换

    /// 替换当前匹配并跳到下一个。
    private func replaceCurrent() {
        guard model.isEditable, let index = findModel.currentIndex, findMatches.indices.contains(index) else { return }
        let span = findMatches[index]
        guard model.selections.primary.range == span else { selectFindMatch(index); return }
        let rope = model.document.snapshot
        let text = replacementText(for: span, in: rope)
        let after = Selection(caret: span.location + text.utf16.count)
        let outcome = EditOutcome(edits: [DocumentEdit(range: span, text: text)], selections: [after])
        model.commit(outcome)
        refreshFind(jump: true)
    }

    /// 全部替换(一次撤销即可还原)。
    private func replaceAllMatches() {
        guard model.isEditable, !findMatches.isEmpty else { return }
        let rope = model.document.snapshot
        let options = findOptions
        let template = findModel.replacement
        var edits: [DocumentEdit] = []
        edits.reserveCapacity(findMatches.count)
        if options.regex, let regex = TextSearch.compile(findModel.query, options: options), rope.length <= 32 * 1024 * 1024 {
            // 正则模板(`$1` 等)需要完整匹配结果,一次性取全文匹配。
            let whole = rope.string()
            let results = regex.matches(in: whole, options: [], range: NSRange(location: 0, length: (whole as NSString).length))
            for result in results where result.range.length > 0 {
                edits.append(DocumentEdit(range: TextSpan(result.range), text: regex.replacementString(for: result, in: whole, offset: 0, template: template)))
            }
        } else {
            for span in findMatches { edits.append(DocumentEdit(range: span, text: template)) }
        }
        let caret = model.selections.primary.range.location
        let outcome = EditOutcome(edits: edits, selections: [Selection(caret: LineOperations.map(caret, through: edits, preferRight: false))])
        model.commit(outcome)
        refreshFind(jump: false)
    }

    /// 某个匹配的替换文本(正则模式展开捕获组)。
    private func replacementText(for span: TextSpan, in rope: TextRope) -> String {
        let template = findModel.replacement
        let options = findOptions
        guard options.regex, let regex = TextSearch.compile(findModel.query, options: options) else { return template }
        // 取包含匹配的整行文本,保证 `^`/`$` 与前后断言行为正确。
        let firstLine = rope.line(containing: span.location)
        let lastLine = rope.line(containing: span.upperBound)
        let start = rope.lineStart(firstLine)
        let end = rope.lineStart(lastLine) + rope.lineLength(lastLine)
        let text = rope.string(in: TextSpan(lower: start, upper: end))
        let local = NSRange(location: span.location - start, length: span.length)
        guard let result = regex.firstMatch(in: text, options: [], range: local), result.range == local else { return template }
        return regex.replacementString(for: result, in: text, offset: 0, template: template)
    }
}
