// @author ixxxxoooo
// 原生编辑器的视图模型:把共享文档(`EditorDocument`)与选区、折叠、软换行、View Zone、装饰组合在一起,
// 并负责在文档变更后增量维护这些派生结构。视图(`OMEditorView`)只读它、通过它修改文档。

import AppKit
import EditorCore

/// 原生编辑器模型(仅主线程)。
@MainActor
public final class NativeEditorModel {
    /// 共享文档。
    public let document: EditorDocument
    /// 当前选区集合。
    public internal(set) var selections: SelectionSet
    /// 语言(决定注释符、缩进单位、括号配对)。
    public var language: SyntaxLanguage
    /// 折叠状态。
    public internal(set) var folds = FoldState()
    /// 视图行映射(折叠 + 软换行)。
    public internal(set) var lineMap: ViewLineMap
    /// View Zone 布局。
    public internal(set) var zoneLayout: ViewZoneLayout
    /// 全部 View Zone(锚点以模型行计)。
    public private(set) var zones: [ViewZone] = []
    /// 装饰集合(诊断、查找命中、Agent 改动……)。
    public var decorations = DecorationSet() { didSet { decorationsRevision &+= 1 } }
    /// 装饰集合的修订号(概览尺等派生缓存据此失效)。
    public private(set) var decorationsRevision = 0
    /// 列宽规则(制表符宽度、全角宽度)。
    public private(set) var metrics = ColumnMetrics()
    /// 软换行列数;`nil` 表示不换行。
    public private(set) var wrapColumns: Double?
    /// 是否可编辑。
    public var isEditable = true
    /// 单次 Tab 插入的缩进单位。
    public var indentUnit = "    "
    /// 是否自动闭合括号与引号。
    public var autoClosePairs = true
    /// 文件名(snippet 变量 `TM_FILENAME` 等使用)。
    public var fileName: String?
    /// 活动的 snippet 会话(Tab 在占位间跳转)。
    public internal(set) var snippetSession: SnippetSession?
    /// 「扩大选择」历史,供「缩小选择」回退。
    var expandHistory: [SelectionSet] = []
    /// 垂直移动时记住的视觉列。
    var preferredColumn: Double?
    /// 文档变更(已更新派生结构)后回调,视图据此失效缓存并重绘。
    public var onDocumentChange: ((DocumentChange) -> Void)?
    /// 选区变化回调。
    public var onSelectionChange: (() -> Void)?
    /// 行换行点缓存(行号 → 续行起点),结构变化时清空。
    private var wrapCache: [Int: [Int]] = [:]
    private var observerToken: Int?
    /// 全文最宽一行的视觉列数估算(不换行时决定横向滚动范围)。
    public private(set) var contentColumns: Double = 0
    /// 递增代数:后台任务回写前用它判断结果是否过期。
    private var generation = 0

    /// 创建模型。
    /// - Parameters:
    ///   - document: 共享文档
    ///   - language: 语言
    ///   - lineHeight: 行高(点)
    public init(document: EditorDocument, language: SyntaxLanguage = .plain, lineHeight: Double = 18) {
        self.document = document
        self.language = language
        self.selections = SelectionSet(caret: 0)
        self.lineMap = ViewLineMap(lineCount: document.lineCount)
        self.zoneLayout = ViewZoneLayout(lineHeight: lineHeight)
        observerToken = document.addObserver { [weak self] change in self?.documentDidChange(change) }
        indentUnit = Self.detectIndentUnit(document.snapshot, language: language)
        recomputeContentColumns()
    }

    deinit {
        // 观察者回调只弱引用本模型;视图销毁时应显式调用 `detach()` 移除。
    }

    /// 从共享文档上摘掉观察者(视图销毁时调用,避免文档长期持有无效回调)。
    public func detach() {
        if let token = observerToken { document.removeObserver(token); observerToken = nil }
    }

    // MARK: 尺寸与配置

    /// 行高(点)。
    public var lineHeight: Double { zoneLayout.lineHeight }

    /// 更新行高。
    public func setLineHeight(_ value: Double) {
        zoneLayout.setLineHeight(value)
        zoneLayout.update(zones: zones, map: lineMap)
    }

    /// 更新列宽规则;换行结果会失效并重算。
    public func setMetrics(_ value: ColumnMetrics) {
        guard value != metrics else { return }
        metrics = value
        reflow()
        recomputeContentColumns()
    }

    /// 设置软换行列数(`nil` 为不换行)。变化时重算全部行的视图行数。
    public func setWrapColumns(_ value: Double?) {
        let normalized = value.map { max(8, $0.rounded(.down)) }
        guard normalized != wrapColumns else { return }
        wrapColumns = normalized
        reflow()
    }

    /// 全部行重新计算换行并重建折叠隐藏。
    public func reflow() {
        wrapCache.removeAll(keepingCapacity: true)
        generation += 1
        let snapshot = document.snapshot
        let columns = wrapColumns
        let metrics = self.metrics
        if columns == nil || snapshot.lineCount <= 60_000 {
            applyRows(WrapRows.compute(rope: snapshot, maxColumns: columns, metrics: metrics))
        } else {
            // 大文件:先以一行一视图行占位,后台算完再回写。
            applyRows([Int32](repeating: 1, count: snapshot.lineCount))
            let token = generation
            Task.detached(priority: .userInitiated) { [weak self] in
                let rows = WrapRows.compute(rope: snapshot, maxColumns: columns, metrics: metrics)
                await MainActor.run {
                    guard let self, self.generation == token, self.document.snapshot.length == snapshot.length else { return }
                    self.applyRows(rows)
                    self.onDocumentChange?(DocumentChange(edits: [], origin: .external, version: self.document.version,
                                                          previous: snapshot, snapshot: snapshot, restoredSelections: nil))
                }
            }
        }
    }

    private func applyRows(_ rows: [Int32]) {
        lineMap.replaceLines(0..<lineMap.lineCount, withRows: rows)
        if !folds.collapsedStarts.isEmpty { lineMap.setHiddenRanges(folds.hiddenRanges()) }
        zoneLayout.update(zones: zones, map: lineMap)
    }

    /// 后台估算最宽行,完成后更新横向滚动范围。
    func recomputeContentColumns() {
        let snapshot = document.snapshot
        let metrics = self.metrics
        if snapshot.lineCount <= 20_000 {
            contentColumns = WrapRows.longestColumns(rope: snapshot, metrics: metrics)
            return
        }
        let token = generation
        Task.detached(priority: .utility) { [weak self] in
            let widest = WrapRows.longestColumns(rope: snapshot, metrics: metrics)
            await MainActor.run {
                guard let self, self.generation == token || self.document.snapshot.length == snapshot.length else { return }
                self.contentColumns = max(self.contentColumns, widest)
                self.onDocumentChange?(DocumentChange(edits: [], origin: .external, version: self.document.version,
                                                      previous: snapshot, snapshot: snapshot, restoredSelections: nil))
            }
        }
    }

    // MARK: View Zone

    /// 设置全部 View Zone 并重新布局。
    public func setZones(_ value: [ViewZone]) {
        zones = value
        zoneLayout.update(zones: zones, map: lineMap)
    }

    // MARK: 折叠

    /// 设置可折叠区域并刷新隐藏行。
    public func setFoldRegions(_ regions: [EditorCore.FoldRegion]) {
        folds.setRegions(regions)
        applyFolds()
    }

    /// 折叠状态变化后同步视图行映射。
    func applyFolds() {
        lineMap.setHiddenRanges(folds.hiddenRanges())
        zoneLayout.update(zones: zones, map: lineMap)
        // 选区落在被隐藏行内时移到折叠起始行末尾。
        let hidden = folds.hiddenRanges()
        guard !hidden.isEmpty else { return }
        let rope = document.snapshot
        var changed = false
        let moved = selections.selections.map { selection -> Selection in
            let line = rope.line(containing: selection.head)
            guard let range = hidden.first(where: { $0.contains(line) }) else { return selection }
            changed = true
            let target = max(range.lowerBound - 1, 0)
            return Selection(caret: rope.lineRange(target)?.upperBound ?? 0)
        }
        if changed { setSelections(SelectionSet(moved)) }
    }

    // MARK: 文档变更

    /// 文档变更后增量维护行映射、折叠、Zone、装饰与选区。
    private func documentDidChange(_ change: DocumentChange) {
        var structural = false
        for edit in change.edits where edit.removedLines != 0 || edit.insertedLines != 0 {
            structural = true
            let oldLines = edit.startLine..<(edit.startLine + edit.removedLines + 1)
            lineMap.replaceLines(oldLines, withRows: [Int32](repeating: 1, count: edit.insertedLines + 1))
            folds.applyLineEdit(startLine: edit.startLine, removedLines: edit.removedLines, insertedLines: edit.insertedLines)
            shiftZones(startLine: edit.startLine, removed: edit.removedLines, inserted: edit.insertedLines)
        }
        wrapCache.removeAll(keepingCapacity: true)
        if structural {
            if !folds.collapsedStarts.isEmpty { lineMap.setHiddenRanges(folds.hiddenRanges()) }
        }
        decorations.apply(edits: change.edits)
        snippetSession?.map(through: change.edits)
        switch change.origin {
        case .undo, .redo:
            if let restored = change.restoredSelections, !restored.isEmpty {
                selections = SelectionSet(restored).clamped(toLength: change.snapshot.length)
            } else {
                selections = selections.mapped(through: change.edits).clamped(toLength: change.snapshot.length)
            }
        case .external:
            selections = selections.mapped(through: change.edits).clamped(toLength: change.snapshot.length)
        case .user:
            break
        }
        if wrapColumns != nil { recomputeRows(for: change) }
        zoneLayout.update(zones: zones, map: lineMap)
        if change.snapshot.length > 0, Double(change.edits.reduce(0) { $0 + $1.newLength }) > 0 {
            // 新增内容可能更宽;精确值由后台扫描修正。
            for edit in change.edits where edit.newLength > 0 && edit.newLength <= 4_096 {
                if let inserted = edit.inserted {
                    contentColumns = max(contentColumns, metrics.columns(of: inserted))
                }
            }
        }
        onDocumentChange?(change)
    }

    private func shiftZones(startLine: Int, removed: Int, inserted: Int) {
        guard !zones.isEmpty else { return }
        let delta = inserted - removed
        zones = zones.map { zone in
            if zone.afterLine < startLine { return zone }
            var next = zone
            if zone.afterLine >= startLine + removed { next.afterLine = zone.afterLine + delta } else { next.afterLine = min(zone.afterLine, startLine + inserted) }
            return next
        }
    }

    /// 重新计算受编辑影响的行的软换行行数。
    private func recomputeRows(for change: DocumentChange) {
        guard let columns = wrapColumns else { return }
        let rope = change.snapshot
        var lines = Set<Int>()
        for (index, edit) in change.edits.enumerated() {
            let rest = Array(change.edits[(index + 1)...])
            let finalOffset = OffsetMapping.map(edit.location, through: rest, bias: .left)
            let first = rope.line(containing: min(finalOffset, rope.length))
            for line in first...(first + edit.insertedLines) where line < rope.lineCount { lines.insert(line) }
        }
        for line in lines {
            guard let range = rope.lineRange(line) else { continue }
            let units = rope.slice(range)
            let count = LineWrapper.wrapPoints(in: units, maxColumns: columns, metrics: metrics).count + 1
            lineMap.setRows(count, ofLine: line)
        }
    }

    // MARK: 换行点

    /// 某行的续行起点(行内 UTF-16 偏移);不换行或短行为空。
    public func wrapPoints(forLine line: Int) -> [Int] {
        guard let columns = wrapColumns else { return [] }
        if let cached = wrapCache[line] { return cached }
        guard let range = document.snapshot.lineRange(line) else { return [] }
        let points: [Int]
        if lineMap.wrapRows(ofLine: line) <= 1, Double(range.length) * max(metrics.wideWidth, Double(metrics.tabSize), 1) <= columns {
            points = []
        } else {
            points = LineWrapper.wrapPoints(in: document.snapshot.slice(range), maxColumns: columns, metrics: metrics)
        }
        if wrapCache.count > 4_000 { wrapCache.removeAll(keepingCapacity: true) }
        wrapCache[line] = points
        return points
    }

    // MARK: 位置换算

    /// 偏移所在的视图行(折叠隐藏的行归到折叠起始行)。
    public func viewRow(ofOffset offset: Int) -> Int {
        let rope = document.snapshot
        let clamped = min(max(offset, 0), rope.length)
        var line = rope.line(containing: clamped)
        var column = clamped - rope.lineStart(line)
        if let hidden = folds.hiddenRanges().first(where: { $0.contains(line) }) {
            line = max(hidden.lowerBound - 1, 0)
            column = rope.lineLength(line)
        }
        let points = wrapPoints(forLine: line)
        var sub = 0
        while sub < points.count, column >= points[sub] { sub += 1 }
        // 恰在换行点上的光标属于下一行(与 Monaco 一致),行尾属于最后一行。
        return lineMap.firstRow(ofLine: line) + sub
    }

    /// 视图行对应的行内区间(行内偏移,半开)与模型行。
    public func rowSpan(ofRow row: Int) -> (line: Int, start: Int, end: Int, isFirst: Bool, isLast: Bool) {
        let located = lineMap.locate(row: row)
        let rope = document.snapshot
        let length = rope.lineLength(located.line)
        let points = wrapPoints(forLine: located.line)
        let start = located.rowInLine == 0 ? 0 : (located.rowInLine - 1 < points.count ? points[located.rowInLine - 1] : length)
        let end = located.rowInLine < points.count ? points[located.rowInLine] : length
        return (located.line, start, end, located.rowInLine == 0, located.rowInLine >= points.count)
    }

    /// 文档内容总高度(含 Zone,不含「滚动超出末行」的留白)。
    public var contentHeight: Double { zoneLayout.contentHeight(totalRows: lineMap.totalRows) }

    // MARK: 选区

    /// 设置选区(夹取到文档范围),并通知视图。
    public func setSelections(_ value: SelectionSet, keepPreferredColumn: Bool = false) {
        let clamped = value.clamped(toLength: document.length)
        guard clamped != selections else { return }
        selections = clamped
        if !keepPreferredColumn { preferredColumn = nil }
        validateSnippetSession()
        onSelectionChange?()
    }

    /// 重新装入文本(切换文件、外部重载):保持文档对象,重置派生状态。
    public func reset(language: SyntaxLanguage) {
        self.language = language
        generation += 1
        wrapCache.removeAll()
        folds = FoldState()
        zones = []
        decorations = DecorationSet()
        lineMap = ViewLineMap(lineCount: document.lineCount)
        zoneLayout.update(zones: [], map: lineMap)
        selections = SelectionSet(caret: 0)
        indentUnit = Self.detectIndentUnit(document.snapshot, language: language)
        reflow()
        recomputeContentColumns()
    }

    /// 由文件前若干行推断缩进单位:多数以制表符缩进则用制表符,否则取最常见的空格缩进宽度。
    static func detectIndentUnit(_ rope: TextRope, language: SyntaxLanguage) -> String {
        var tabLines = 0
        var spaceWidths: [Int: Int] = [:]
        let limit = min(rope.lineCount, 400)
        var previousIndent = 0
        for line in 0..<limit {
            guard let range = rope.lineRange(line), range.length > 0 else { continue }
            let lead = CursorMotion.leadingWhitespaceLength(ofLine: line, in: rope)
            if lead == 0 { previousIndent = 0; continue }
            if rope.unit(at: range.location) == 9 { tabLines += 1; continue }
            let delta = abs(lead - previousIndent)
            if delta >= 2 && delta <= 8 { spaceWidths[delta, default: 0] += 1 }
            previousIndent = lead
        }
        let spaces = spaceWidths.values.reduce(0, +)
        if tabLines > spaces && tabLines > 2 { return "\t" }
        if let best = spaceWidths.max(by: { $0.value < $1.value })?.key { return String(repeating: " ", count: best) }
        return EditorEditing.indentUnit(for: language)
    }
}
