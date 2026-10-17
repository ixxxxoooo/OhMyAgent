// @author ixxxxoooo
// 编辑器内查找/替换:⌘F 打开悬浮查找条,匹配用 TextKit 2 渲染属性高亮(不改文本、不进撤销栈)。

import AppKit
import DesignSystem
import SwiftUI

extension CodeEditorView {
    /// 最近获得焦点的编辑器(菜单命令在焦点不在文本区时的兜底)。
    static weak var lastFocused: CodeEditorView?

    /// 当前应响应查找命令的编辑器:键盘焦点所在的编辑器,否则最近聚焦且仍可见的编辑器。
    /// - Returns: 编辑器;没有时为 nil
    public static func activeEditor() -> CodeEditorView? {
        var view = NSApp.keyWindow?.firstResponder as? NSView
        while let current = view {
            if let editor = current as? CodeEditorView { return editor }
            view = current.superview
        }
        if let editor = lastFocused, editor.window != nil, !editor.isHiddenOrHasHiddenAncestor { return editor }
        return nil
    }

    /// 在当前编辑器里打开查找条。
    /// - Parameter replace: 是否同时展开替换行
    /// - Returns: 是否有编辑器响应
    @discardableResult
    public static func showFindInActiveEditor(replace: Bool = false) -> Bool {
        guard let editor = activeEditor() else { return false }
        editor.showFind(replace: replace)
        return true
    }

    /// 在当前编辑器里跳到下一个/上一个匹配(查找条未打开时先打开)。
    /// - Parameter forward: 方向
    /// - Returns: 是否有编辑器响应
    @discardableResult
    public static func findInActiveEditor(forward: Bool) -> Bool {
        guard let editor = activeEditor() else { return false }
        if editor.findHost == nil { editor.showFind() } else { editor.findStep(forward: forward) }
        return true
    }

    // MARK: 显示与关闭

    /// 打开(或聚焦)查找条;有单行选区时用它作为查询词。
    /// - Parameter replace: 是否展开替换行
    public func showFind(replace: Bool = false) {
        findModel.isEditable = textView.isEditable
        if replace, textView.isEditable { findModel.showsReplace = true }
        let selected = textView.selectedRange()
        if selected.length > 0, selected.length < 200, let range = Range(selected, in: textView.string) {
            let text = String(textView.string[range])
            if !text.contains("\n") { findModel.query = text }
        }
        if findHost == nil {
            findModel.onSearchChange = { [weak self] in self?.refreshFind(jump: true) }
            findModel.onNext = { [weak self] in self?.findStep(forward: true) }
            findModel.onPrevious = { [weak self] in self?.findStep(forward: false) }
            findModel.onReplace = { [weak self] in self?.replaceCurrent() }
            findModel.onReplaceAll = { [weak self] in self?.replaceAll() }
            findModel.onClose = { [weak self] in self?.hideFind() }
            let host = NSHostingView(rootView: EditorFindBar(model: findModel))
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: topAnchor, constant: -4),
                host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            ])
            findHost = host
        }
        findModel.focusToken += 1
        refreshFind(jump: true)
    }

    /// 关闭查找条并清除高亮,焦点回到文本区。
    func hideFind() {
        findRefreshTask?.cancel()
        clearFindHighlights()
        findResults = []
        findHost?.removeFromSuperview()
        findHost = nil
        window?.makeFirstResponder(textView)
    }

    // MARK: 搜索与高亮

    /// 文本或查询变化后重新搜索。
    /// - Parameter jump: 是否跳到离光标最近的匹配并选中
    func refreshFind(jump: Bool) {
        guard findHost != nil else { return }
        findRefreshTask?.cancel()
        let regex = EditorFindEngine.compile(query: findModel.query, options: findModel.options)
        findModel.isInvalidPattern = !findModel.query.isEmpty && regex == nil
        findRegex = regex
        findResults = regex.map { EditorFindEngine.matches(of: $0, in: textView.string) } ?? []
        findModel.matchCount = findResults.count
        let selection = textView.selectedRange()
        if jump, let index = EditorFindEngine.index(in: findResults.map(\.range), from: selection.location, forward: true) {
            selectFindMatch(index, reveal: true)
        } else {
            findModel.currentIndex = findResults.isEmpty ? nil : min(findModel.currentIndex ?? 0, findResults.count - 1)
            applyFindHighlights()
        }
    }

    /// 文本被编辑后的防抖刷新(保持当前位置,不抢选区)。
    func scheduleFindRefresh() {
        guard findHost != nil else { return }
        findRefreshTask?.cancel()
        findRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.refreshFind(jump: false)
        }
    }

    /// 跳到下一个/上一个匹配。
    /// - Parameter forward: 方向
    func findStep(forward: Bool) {
        guard !findResults.isEmpty else { return }
        let selection = textView.selectedRange()
        let from = forward ? selection.location + selection.length : selection.location
        let ranges = findResults.map(\.range)
        guard let index = EditorFindEngine.index(in: ranges, from: from, forward: forward) else { return }
        selectFindMatch(index, reveal: true)
    }

    /// 选中并滚动到某个匹配。
    private func selectFindMatch(_ index: Int, reveal: Bool) {
        guard findResults.indices.contains(index) else { return }
        let range = findResults[index].range
        findModel.currentIndex = index
        textView.setSelectedRange(range)
        if reveal {
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }
        applyFindHighlights()
    }

    /// 清除所有查找高亮。
    private func clearFindHighlights() {
        guard let layout = textView.textLayoutManager else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange)
    }

    /// 重画高亮:当前匹配用强调色,其余用警示色淡底(只画当前附近的一批,超大结果集不卡)。
    private func applyFindHighlights() {
        clearFindHighlights()
        guard let layout = textView.textLayoutManager, let content = textView.textContentStorage else { return }
        let window = 1_500
        let current = findModel.currentIndex ?? 0
        let lower = max(0, current - window), upper = min(findResults.count, current + window)
        guard lower < upper else { return }
        let others = NSColor(OMColors.warning).withAlphaComponent(0.28)
        let active = NSColor(OMColors.accent).withAlphaComponent(0.5)
        for index in lower..<upper {
            guard let range = content.textRange(findResults[index].range) else { continue }
            layout.addRenderingAttribute(.backgroundColor, value: index == findModel.currentIndex ? active : others, for: range)
        }
    }

    /// 主题变化后重画高亮。
    func findThemeDidChange() {
        if findHost != nil { applyFindHighlights() }
    }

    // MARK: 替换

    /// 替换当前匹配并跳到下一个。
    private func replaceCurrent() {
        guard textView.isEditable, let regex = findRegex, let index = findModel.currentIndex, findResults.indices.contains(index) else { return }
        let result = findResults[index]
        guard textView.selectedRange() == result.range else {
            selectFindMatch(index, reveal: true)
            return
        }
        let text = EditorFindEngine.replacement(for: result, regex: regex, in: textView.string, template: findModel.replacement, options: findModel.options)
        guard textView.shouldChangeText(in: result.range, replacementString: text) else { return }
        textView.replaceCharacters(in: result.range, with: text)
        textView.didChangeText()
        let resume = result.range.location + (text as NSString).length
        textView.setSelectedRange(NSRange(location: resume, length: 0))
        refreshFind(jump: true)
    }

    /// 全部替换(一次撤销即可还原)。
    private func replaceAll() {
        guard textView.isEditable, let regex = findRegex, !findResults.isEmpty else { return }
        let original = textView.string
        let source = original as NSString
        var output = ""
        var cursor = 0
        for result in findResults {
            output += source.substring(with: NSRange(location: cursor, length: result.range.location - cursor))
            output += EditorFindEngine.replacement(for: result, regex: regex, in: original, template: findModel.replacement, options: findModel.options)
            cursor = result.range.location + result.range.length
        }
        output += source.substring(from: cursor)
        let whole = NSRange(location: 0, length: source.length)
        guard textView.shouldChangeText(in: whole, replacementString: output) else { return }
        textView.textStorage?.replaceCharacters(in: whole, with: output)
        textView.didChangeText()
        refreshFind(jump: false)
    }
}
