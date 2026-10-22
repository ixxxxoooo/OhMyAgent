// @author ixxxxoooo
// 代码折叠(I7):用 TextKit 2 内容管理器代理的 `shouldEnumerate` 隐藏被折叠的段落(行),
// 行号栏在块头行显示折叠箭头,折叠范围随编辑平移(编辑落进范围内则自动展开)。
// 区间推断见 `EditorFolding`(按缩进与块头)。

import AppKit

/// 行号栏里一行的折叠状态。
enum FoldGlyph {
    case none, expanded, collapsed
}

extension CodeEditorView: @preconcurrency NSTextContentStorageDelegate {
    /// 被折叠的段落不参与布局与枚举。
    public func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement, options: NSTextContentManager.EnumerationOptions = []) -> Bool {
        guard !foldedRanges.isEmpty, let storage = textContentManager as? NSTextContentStorage,
              let range = textElement.elementRange else { return true }
        return !EditorFolding.isHidden(storage.nsRange(range).location, in: foldedRanges)
    }
}

extension CodeEditorView {
    /// 某行(0 起始)的文本;越界返回 nil。
    func lineText(_ line: Int) -> String? {
        guard line >= 0, let range = lineIndex.range(ofLine: line) else { return nil }
        let ns = textView.string as NSString
        guard NSMaxRange(range) <= ns.length else { return nil }
        return ns.substring(with: range)
    }

    /// 以某行为块头的折叠区域(行索引未就绪时为 nil)。
    func foldRegion(headerLine line: Int) -> FoldRegion? {
        guard lineIndexIsLive else { return nil }
        return EditorFolding.region(startingAt: line, lineCount: lineIndex.lineCount) { lineText($0) }
    }

    /// 行号栏用的快速判断:该行是块头且下一个非空行缩进更深(不扫描整块)。
    func foldGlyph(forLine line: Int) -> FoldGlyph {
        guard chrome.contains(.folding), lineIndexIsLive else { return .none }
        if isFolded(headerLine: line) { return .collapsed }
        guard let header = lineText(line), EditorScopes.opensBlock(header), let base = EditorScopes.indent(of: header) else { return .none }
        var next = line + 1
        while next < min(lineIndex.lineCount, line + 40) {
            if let content = lineText(next), let columns = EditorScopes.indent(of: content) { return columns > base ? .expanded : .none }
            next += 1
        }
        return .none
    }

    /// 该块头行当前是否已折叠。
    func isFolded(headerLine line: Int) -> Bool {
        guard !foldedRanges.isEmpty, let next = lineIndex.range(ofLine: line + 1) else { return false }
        return EditorFolding.isHidden(next.location, in: foldedRanges)
    }

    /// 当前已折叠的块头行(升序)。
    public var foldedHeaderLines: [Int] {
        foldedRanges.map { max(lineIndex.line(containing: $0.location) - 1, 0) }
    }

    // MARK: 操作

    /// 切换某块头行(0 起始)的折叠状态。
    /// - Parameter line: 块头行
    public func toggleFold(line: Int) {
        if isFolded(headerLine: line) { unfold(line: line) } else { fold(line: line) }
    }

    /// 折叠某块头行的正文;该行不可折叠时无事发生。
    /// - Parameter line: 块头行(0 起始)
    public func fold(line: Int) {
        guard chrome.contains(.folding), let region = foldRegion(headerLine: line),
              let range = EditorFolding.hiddenRange(for: region.body, lineStart: { self.lineIndex.range(ofLine: $0)?.location }, textLength: lineIndex.length) else { return }
        // 范围内已折叠的子区域随外层一起隐藏
        var ranges = foldedRanges.filter { NSIntersectionRange($0, range).length == 0 }
        ranges.append(range)
        ranges.sort { $0.location < $1.location }
        setFolds(ranges, keepingCaretVisible: true)
    }

    /// 展开某块头行。
    /// - Parameter line: 块头行(0 起始)
    public func unfold(line: Int) {
        guard let next = lineIndex.range(ofLine: line + 1) else { return }
        setFolds(foldedRanges.filter { !NSLocationInRange(next.location, $0) }, keepingCaretVisible: false)
    }

    /// 折叠光标所在位置最内层的可折叠块(光标行本身是块头,或向上找到包含光标行的块头)。
    public func foldAtCaret() {
        guard lineIndexIsLive else { return }
        let line = lineIndex.line(containing: textView.selectedRange().location)
        var candidate = line
        let stop = max(0, line - 3000)
        while candidate >= stop {
            if let region = foldRegion(headerLine: candidate), candidate == line || region.body.contains(line) {
                if !isFolded(headerLine: candidate) { fold(line: candidate); return }
            }
            candidate -= 1
        }
    }

    /// 展开光标所在行(块头)的折叠。
    public func unfoldAtCaret() {
        let line = lineIndex.line(containing: textView.selectedRange().location)
        if isFolded(headerLine: line) { unfold(line: line) }
    }

    /// 折叠全部最外层块。
    public func foldAll() {
        guard chrome.contains(.folding), lineIndexIsLive else { return }
        let regions = EditorFolding.outermost(EditorFolding.allRegions(lineCount: lineIndex.lineCount) { lineText($0) })
        let ranges = regions.compactMap { region in
            EditorFolding.hiddenRange(for: region.body, lineStart: { self.lineIndex.range(ofLine: $0)?.location }, textLength: lineIndex.length)
        }
        setFolds(ranges, keepingCaretVisible: true)
    }

    /// 展开全部。
    public func unfoldAll() {
        setFolds([], keepingCaretVisible: false)
    }

    /// 让某字符位置可见:落在被折叠范围内时展开该范围(跳转到行、查找定位用)。
    /// - Parameter location: UTF-16 偏移
    func revealFolded(at location: Int) {
        guard EditorFolding.isHidden(location, in: foldedRanges) else { return }
        setFolds(foldedRanges.filter { !NSLocationInRange(location, $0) }, keepingCaretVisible: false)
    }

    /// 应用新的折叠范围并让文本布局重新枚举段落。
    private func setFolds(_ ranges: [NSRange], keepingCaretVisible: Bool) {
        guard ranges != foldedRanges else { return }
        foldedRanges = ranges
        if keepingCaretVisible {
            // 光标被折叠藏起来时,挪到块头行末尾
            let caret = textView.selectedRange()
            if let hidden = ranges.first(where: { NSLocationInRange(caret.location, $0) }) {
                let headerLine = max(lineIndex.line(containing: hidden.location) - 1, 0)
                if let header = lineIndex.range(ofLine: headerLine) {
                    let ns = textView.string as NSString
                    var end = NSMaxRange(header)
                    if end > header.location, end <= ns.length, ns.character(at: end - 1) == 10 { end -= 1 }
                    textView.setSelectedRange(NSRange(location: end, length: 0))
                }
            }
        }
        relayoutForFolding()
    }

    /// 内容管理器缓存了段落枚举结果;标记属性变化让它按新的 `shouldEnumerate` 重新生成,再重画行号栏。
    func relayoutForFolding() {
        guard let storage = textView.textStorage, let layoutManager = textView.textLayoutManager else { return }
        (layoutManager.textContentManager as? NSTextContentStorage)?.performEditingTransaction {
            storage.edited(.editedAttributes, range: NSRange(location: 0, length: storage.length), changeInLength: 0)
        }
        layoutManager.invalidateLayout(for: layoutManager.documentRange)
        textView.needsLayout = true
        textView.needsDisplay = true
        ruler.needsDisplay = true
        minimap?.needsDisplay = true
        sticky?.refresh()
        scheduleHighlight()
    }

    /// 文本被编辑:折叠范围随之平移或展开(`storageDidProcessEditing` 调用)。
    func adjustFolds(edited: NSRange, delta: Int) {
        guard !foldedRanges.isEmpty else { return }
        foldedRanges = EditorFolding.adjust(hidden: foldedRanges, edited: edited, delta: delta)
    }
}
