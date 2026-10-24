// @author ixxxxoooo
// 原生编辑视图的外围能力:缩进参考线、概览尺(右缘缩略标记)、粘性滚动、括号匹配高亮、缩略图装配。

import AppKit
import CoreText
import DesignSystem
import EditorCore

/// 概览尺上的一个标记。
struct OverviewMark {
    var y: CGFloat
    var color: NSColor
    /// true 画在左侧窄道(行级改动),false 画在主道(诊断/查找命中)。
    var narrow: Bool
}

/// 概览尺缓存键:任一项变化就重算。
struct OverviewKey: Equatable {
    var decorations = -1
    var markers = -1
    var rows = -1
    var height: CGFloat = -1
    var version = -1
}

extension OMEditorView {
    /// 概览尺宽度。
    static let rulerWidth: CGFloat = 8

    /// 文本区右侧让出的宽度(缩略图 + 概览尺)。
    var rightInset: CGFloat {
        var inset: CGFloat = 0
        if chrome.contains(.minimap) { inset += NativeMinimapView.width }
        if chrome.contains(.overviewRuler) || chrome.contains(.minimap) { inset += Self.rulerWidth }
        return inset
    }

    /// 缩进一个层级对应的视觉列数。
    var indentUnitColumns: Int {
        model.indentUnit == "\t" ? max(model.metrics.tabSize, 2) : max(model.indentUnit.count, 2)
    }

    // MARK: 装配

    func chromeDidChange() {
        if chrome.contains(.minimap) {
            if minimap == nil {
                let view = NativeMinimapView(editor: self)
                minimap = view
                addSubview(view)
            }
        } else if let view = minimap {
            view.removeFromSuperview()
            minimap = nil
        }
        if !chrome.contains(.stickyScroll) { stickyLines = [] }
        let wantsFolds = chrome.contains(.folding)
        if wantsFolds != model.tracksFolds {
            model.tracksFolds = wantsFolds
            if wantsFolds { model.refreshFoldRegions() } else { model.setFoldRegions([]) }
        }
        layoutMinimap()
        applyWrapSettings(immediate: true)
        refreshSticky()
        needsDisplay = true
    }

    /// 摆放缩略图(位于概览尺左侧,占满高度)。
    func layoutMinimap() {
        guard let minimap else { return }
        let ruler = Self.rulerWidth
        minimap.frame = CGRect(x: bounds.width - NativeMinimapView.width - ruler, y: 0, width: NativeMinimapView.width, height: bounds.height)
    }

    // MARK: 缩进参考线

    /// 某行用于参考线的缩进列数:空白行取上下最近非空行的较小值。
    private func effectiveIndent(ofLine line: Int, lineCount: Int) -> Int {
        let layout = cache.layout(forLine: line)
        if !layout.isBlank { return layout.leadingColumns }
        var before: Int?
        var after: Int?
        var index = line - 1
        while index >= max(line - 30, 0) {
            let other = cache.layout(forLine: index)
            if !other.isBlank { before = other.leadingColumns; break }
            index -= 1
        }
        index = line + 1
        while index < min(line + 30, lineCount) {
            let other = cache.layout(forLine: index)
            if !other.isBlank { after = other.leadingColumns; break }
            index += 1
        }
        return min(before ?? 0, after ?? 0)
    }

    func drawIndentGuides(rows: [NativeDrawRow]) {
        guard !rows.isEmpty else { return }
        let unit = indentUnitColumns
        let lineCount = model.document.lineCount
        var effective: [Int: Int] = [:]
        func indent(of line: Int) -> Int {
            if let known = effective[line] { return known }
            let value = effectiveIndent(ofLine: line, lineCount: lineCount)
            effective[line] = value
            return value
        }
        // 光标所在块的参考线(激活态):向上下扩展到缩进更浅的行为止。
        let caretLine = model.document.snapshot.line(containing: model.selections.primary.head)
        var activeLevel = -1
        var activeRange: ClosedRange<Int>?
        if let caretIndex = rows.firstIndex(where: { $0.line == caretLine }) {
            let caretIndent = indent(of: caretLine)
            activeLevel = caretIndent / unit - 1
            if activeLevel >= 0 {
                let threshold = (activeLevel + 1) * unit
                var lower = caretIndex, upper = caretIndex
                while lower > 0, indent(of: rows[lower - 1].line) >= threshold { lower -= 1 }
                while upper + 1 < rows.count, indent(of: rows[upper + 1].line) >= threshold { upper += 1 }
                activeRange = rows[lower].row...rows[upper].row
            }
        }
        let normal = theme.foreground.withAlphaComponent(0.10)
        let active = theme.foreground.withAlphaComponent(0.34)
        for item in rows {
            let levels = indent(of: item.line) / unit
            guard levels > 0 else { continue }
            for level in 0..<levels {
                let x = (textOriginX + CGFloat(level * unit) * columnWidth).rounded(.down) + 0.5
                guard x >= gutterWidth else { continue }
                (level == activeLevel && activeRange?.contains(item.row) == true ? active : normal).setFill()
                NSRect(x: x, y: item.y, width: 1, height: lineHeight).fill()
            }
        }
    }

    // MARK: 概览尺

    func drawOverviewRuler(rows: [NativeDrawRow]) {
        guard chrome.contains(.overviewRuler) || chrome.contains(.minimap) else { return }
        let x = bounds.width - Self.rulerWidth
        theme.background.setFill()
        NSRect(x: x, y: 0, width: Self.rulerWidth, height: bounds.height).fill()
        refreshOverviewMarks()
        for mark in overviewMarks {
            mark.color.setFill()
            if mark.narrow {
                NSRect(x: x, y: mark.y, width: 3, height: 2).fill()
            } else {
                NSRect(x: x + 3, y: mark.y, width: Self.rulerWidth - 3, height: 2).fill()
            }
        }
        // 当前光标位置的细线。
        let total = max(model.lineMap.totalRows, 1)
        let row = model.viewRow(ofOffset: model.selections.primary.head)
        theme.foreground.withAlphaComponent(0.35).setFill()
        NSRect(x: x, y: (CGFloat(row) / CGFloat(total) * bounds.height).rounded(), width: Self.rulerWidth, height: 1).fill()
    }

    /// 需要时重算概览尺标记。
    private func refreshOverviewMarks() {
        let key = OverviewKey(decorations: model.decorationsRevision, markers: markersRevision, rows: model.lineMap.totalRows,
                              height: bounds.height, version: model.document.version)
        guard key != overviewKey else { return }
        overviewKey = key
        let rope = model.document.snapshot
        let totalRows = max(model.lineMap.totalRows, 1)
        let height = bounds.height
        func y(ofOffset offset: Int) -> CGFloat {
            let line = rope.line(containing: min(max(offset, 0), rope.length))
            return (CGFloat(model.lineMap.firstRow(ofLine: line)) / CGFloat(totalRows) * height).rounded()
        }
        var marks: [OverviewMark] = []
        var seen = Set<Int>()
        func add(_ yValue: CGFloat, _ color: NSColor, narrow: Bool, tag: Int) {
            // 同色同像素行只画一次。
            let slot = Int(yValue) * 16 + tag
            if seen.insert(slot).inserted { marks.append(OverviewMark(y: yValue, color: color, narrow: narrow)) }
        }
        if model.decorations.count > 0 {
            let all = model.decorations.intersecting(TextSpan(location: 0, length: rope.length))
            let stride = max(all.count / 20_000, 1)
            for (index, decoration) in all.enumerated() where index % stride == 0 {
                switch decoration.kind {
                case .diagnosticError: add(y(ofOffset: decoration.range.location), NSColor(OMColors.danger), narrow: false, tag: 1)
                case .diagnosticWarning: add(y(ofOffset: decoration.range.location), NSColor(OMColors.warning), narrow: false, tag: 2)
                case .diagnosticInfo: add(y(ofOffset: decoration.range.location), NSColor(OMColors.accent), narrow: false, tag: 3)
                case .findMatch, .findCurrent: add(y(ofOffset: decoration.range.location), NSColor(OMColors.warning).withAlphaComponent(0.9), narrow: false, tag: 4)
                case .selectionMatch, .wordHighlight: add(y(ofOffset: decoration.range.location), theme.foreground.withAlphaComponent(0.4), narrow: false, tag: 5)
                case .agentAdded, .gitAdded: add(y(ofOffset: decoration.range.location), NSColor(OMColors.diffAdded), narrow: true, tag: 6)
                case .agentRemoved, .gitRemoved: add(y(ofOffset: decoration.range.location), NSColor(OMColors.diffRemoved), narrow: true, tag: 7)
                case .agentModified, .gitModified: add(y(ofOffset: decoration.range.location), NSColor(OMColors.warning), narrow: true, tag: 8)
                default: break
                }
            }
        }
        for (line, marker) in lineMarkers {
            let yValue = (CGFloat(model.lineMap.firstRow(ofLine: line)) / CGFloat(totalRows) * height).rounded()
            add(yValue, Self.markerColor(marker), narrow: true, tag: 9 + Self.markerTag(marker))
        }
        overviewMarks = marks
    }

    private static func markerTag(_ marker: LineMarker) -> Int {
        switch marker {
        case .added: 0
        case .removed: 1
        case .modified: 2
        case .agent: 3
        }
    }

    // MARK: 粘性滚动

    /// 按当前滚动位置重算粘性块头(顶行或文档版本变化才重算)。
    func refreshSticky() {
        guard chrome.contains(.stickyScroll) else {
            if !stickyLines.isEmpty { stickyLines = []; needsDisplay = true }
            return
        }
        let rope = model.document.snapshot
        // 顶部没有内容被遮住时不需要粘性行。
        guard scrollY > 0 else {
            if !stickyLines.isEmpty { stickyLines = []; needsDisplay = true }
            stickyKey = StickyKey(topLine: 0, version: model.document.version)
            return
        }
        // 顶行与文档版本都没变就不必重扫(滚动时绝大多数事件落在同一行内;扫描最多读 800 行文本)
        let currentTop = model.lineMap.locate(row: row(atY: CGFloat(stickyLines.count) * lineHeight)).line
        if StickyKey(topLine: currentTop, version: model.document.version) == stickyKey { return }
        // 参考行 = 粘性区域下方第一行;粘性行数又取决于参考行,迭代至稳定(最多 3 次)。
        var count = stickyLines.count
        var found: [Int] = []
        var topLine = 0
        for _ in 0..<3 {
            topLine = model.lineMap.locate(row: row(atY: CGFloat(count) * lineHeight)).line
            found = EditorScopes.enclosing(topLine: topLine, limit: 3, scanLimit: 800, lineCount: rope.lineCount) { line in
                rope.lineLength(line) < 400 ? rope.lineText(line) : nil
            }
            if found.count == count { break }
            count = found.count
        }
        let key = StickyKey(topLine: topLine, version: model.document.version)
        guard key != stickyKey || found != stickyLines else { return }
        stickyKey = key
        if found != stickyLines {
            stickyLines = found
            needsDisplay = true
        }
    }

    func drawSticky() {
        guard !stickyLines.isEmpty else { return }
        let height = stickyHeight
        theme.background.setFill()
        NSRect(x: gutterWidth, y: 0, width: textArea.width, height: height).fill()
        theme.gutterBackground.setFill()
        NSRect(x: 0, y: 0, width: gutterWidth, height: height).fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let baseline = (lineHeight - (ascent + descent)) / 2 + ascent
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: theme.gutterForeground]
        context.saveGState()
        context.clip(to: CGRect(x: gutterWidth, y: 0, width: textArea.width, height: height))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in stickyLines.enumerated() {
            guard let first = cache.layout(forLine: line).rows.first else { continue }
            context.textPosition = CGPoint(x: textOriginX, y: CGFloat(index) * lineHeight + baseline)
            CTLineDraw(first.ctLine, context)
        }
        context.restoreGState()
        for (index, line) in stickyLines.enumerated() {
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: numberAttributes)
            label.draw(at: NSPoint(x: gutterWidth - foldColumnWidth - 8 - size.width, y: CGFloat(index) * lineHeight + (lineHeight - size.height) / 2), withAttributes: numberAttributes)
        }
        theme.foreground.withAlphaComponent(0.14).setFill()
        NSRect(x: 0, y: height - 1, width: bounds.width - rightInset, height: 1).fill()
    }

    /// 点击粘性区域:跳到对应块头行。
    func stickyClick(at point: CGPoint) -> Bool {
        guard !stickyLines.isEmpty, point.y < stickyHeight, point.x < textArea.maxX else { return false }
        let index = min(max(Int(point.y / lineHeight), 0), stickyLines.count - 1)
        goToLine(stickyLines[index])
        return true
    }

    /// 跳转到某行(0 起始):光标放到行首非空白处并滚动到视口上部。
    public func goToLine(_ line: Int) {
        let rope = model.document.snapshot
        let target = min(max(line, 0), max(rope.lineCount - 1, 0))
        let start = rope.lineStart(target) + CursorMotion.leadingWhitespaceLength(ofLine: target, in: rope)
        model.setSelections(SelectionSet(caret: start))
        scrollToLine(target, centered: false)
        scroll(y: scrollY - stickyHeight - lineHeight * 2)
    }

    // MARK: 括号匹配

    /// 光标紧邻括号时,高亮它与配对括号。
    func updateBracketMatch() {
        var wanted: (Int, Int)?
        if !model.selections.isMulti, model.selections.primary.isEmpty {
            wanted = brackets.match(at: model.selections.primary.head, rope: model.document.snapshot)
        }
        if hasBracketMatch {
            model.decorations.removeAll { $0.kind == .bracketMatch }
            hasBracketMatch = false
        }
        if let (first, second) = wanted {
            model.decorations.insert(Decoration(id: 2_000_000, range: TextSpan(location: first, length: 1), kind: .bracketMatch, removesWhenCollapsed: true))
            model.decorations.insert(Decoration(id: 2_000_001, range: TextSpan(location: second, length: 1), kind: .bracketMatch, removesWhenCollapsed: true))
            hasBracketMatch = true
        }
    }
}
