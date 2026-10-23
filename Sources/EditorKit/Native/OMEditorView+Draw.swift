// @author ixxxxoooo
// 原生编辑视图的绘制:背景 → 当前行 → 选区/装饰底色 → 文本 → 下划线/波浪线 → 光标 → 行号栏 → 滚动条。
// 只绘制可见行,所有排版来自行缓存,绘制本身不做文本分析。

import AppKit
import CoreText
import DesignSystem
import EditorCore

/// 一个可见视图行的绘制上下文。
struct NativeDrawRow {
    let row: Int
    let line: Int
    let rowInLine: Int
    /// 行顶部 y(视图坐标)。
    let y: CGFloat
    let layout: NativeRowLayout
    /// 该逻辑行起点的文档偏移。
    let lineStart: Int
    /// 行内 `start`/`end` 对应的文档偏移。
    var absoluteStart: Int { lineStart + layout.start }
    var absoluteEnd: Int { lineStart + layout.end }
}

extension OMEditorView {
    // MARK: 可见行

    /// 收集当前视口内的行(含排版)。
    func visibleDrawRows() -> [NativeDrawRow] {
        let total = model.lineMap.totalRows
        guard total > 0 else { return [] }
        let rope = model.document.snapshot
        var row = max(self.row(atY: 0) - 1, 0)
        var result: [NativeDrawRow] = []
        result.reserveCapacity(Int(bounds.height / lineHeight) + 4)
        var cachedLine = -1
        var cachedStart = 0
        while row < total {
            let y = rowTop(row)
            if y > bounds.height { break }
            if y + lineHeight >= 0, let found = cache.rowLayout(forRow: row) {
                if found.line != cachedLine {
                    cachedLine = found.line
                    cachedStart = rope.lineStart(found.line)
                }
                result.append(NativeDrawRow(row: row, line: found.line, rowInLine: found.rowInLine, y: y, layout: found.layout, lineStart: cachedStart))
            }
            row += 1
        }
        return result
    }

    /// 文档区间在可见行里对应的矩形(每行一个,换行续行各自一段)。
    /// - Parameters:
    ///   - range: 文档区间
    ///   - rows: 可见行
    ///   - extendNewline: 区间越过行尾换行时,是否在行尾多画一小段
    func segments(for range: TextSpan, rows: [NativeDrawRow], extendNewline: Bool = false) -> [CGRect] {
        var rects: [CGRect] = []
        for item in rows {
            let start = item.absoluteStart, end = item.absoluteEnd
            let isLastRow = item.layout.end >= model.document.snapshot.lineLength(item.line)
            let lower = max(range.location, start)
            let upper = min(range.upperBound, end)
            let touchesNewline = extendNewline && isLastRow && range.upperBound > end && range.location <= end
            guard upper > lower || touchesNewline else { continue }
            let x1 = textOriginX + item.layout.x(forOffset: lower - item.lineStart)
            var x2 = textOriginX + item.layout.x(forOffset: max(upper, lower) - item.lineStart)
            if touchesNewline { x2 += max(columnWidth * 0.6, 4) }
            if x2 <= x1 { continue }
            rects.append(CGRect(x: x1, y: item.y, width: x2 - x1, height: lineHeight))
        }
        return rects
    }

    // MARK: 主绘制

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        theme.background.setFill()
        dirtyRect.fill()
        let rows = visibleDrawRows()
        let rope = model.document.snapshot

        // 文本区域内的内容统一裁剪,避免横向滚动时文字压到行号栏上。
        context.saveGState()
        context.clip(to: textArea)
        drawCurrentLine(rows: rows, in: context)
        drawIndentGuides(rows: rows)
        drawSelections(rows: rows)
        drawDecorationBackgrounds(rows: rows)
        drawText(rows: rows, in: context)
        drawDecorationForegrounds(rows: rows)
        drawMarkedText(rows: rows)
        drawCarets(rows: rows, rope: rope)
        context.restoreGState()

        drawGutter(rows: rows)
        drawSticky()
        drawOverviewRuler(rows: rows)
        drawScrollbars()
    }

    private func drawCurrentLine(rows: [NativeDrawRow], in context: CGContext) {
        let selections = model.selections
        guard !selections.isMulti, selections.primary.isEmpty, window?.firstResponder === self else { return }
        let caretLine = model.document.snapshot.line(containing: selections.primary.head)
        theme.currentLine.setFill()
        for item in rows where item.line == caretLine && item.rowInLine == 0 {
            // 软换行行整体高亮。
            let rowCount = model.lineMap.wrapRows(ofLine: item.line)
            NSRect(x: gutterWidth, y: item.y, width: textArea.width, height: lineHeight * CGFloat(rowCount)).fill()
        }
    }

    private func drawSelections(rows: [NativeDrawRow]) {
        let color = NSColor(OMColors.accent).withAlphaComponent(window?.firstResponder === self ? 0.28 : 0.16)
        color.setFill()
        for selection in model.selections.selections where !selection.isEmpty {
            for rect in segments(for: selection.range, rows: rows, extendNewline: true) { rect.fill() }
        }
    }

    private func drawText(rows: [NativeDrawRow], in context: CGContext) {
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let scale = window?.backingScaleFactor ?? 2
        let baseline = ((lineHeight - (ascent + descent)) / 2 + ascent)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for item in rows {
            let y = ((item.y + baseline) * scale).rounded() / scale
            context.textPosition = CGPoint(x: textOriginX, y: y)
            CTLineDraw(item.layout.ctLine, context)
        }
    }

    private func drawCarets(rows: [NativeDrawRow], rope: TextRope) {
        guard caretVisible, window?.firstResponder === self, window?.isKeyWindow == true else { return }
        theme.foreground.setFill()
        for selection in model.selections.selections {
            let head = selection.head
            for item in rows where head >= item.absoluteStart && head <= item.absoluteEnd {
                // 恰在续行起点的光标只画在下一行(与 viewRow 规则一致)。
                if head == item.absoluteEnd, !(item.layout.end >= rope.lineLength(item.line)) { continue }
                let x = textOriginX + item.layout.x(forOffset: head - item.lineStart)
                NSRect(x: x - 1, y: item.y, width: 2, height: lineHeight).fill()
                break
            }
        }
    }

    // MARK: 装饰

    private func drawDecorationBackgrounds(rows: [NativeDrawRow]) {
        guard let first = rows.first, let last = rows.last, model.decorations.count > 0 else { return }
        let visible = TextSpan(lower: first.absoluteStart, upper: last.absoluteEnd)
        for decoration in model.decorations.intersecting(visible) {
            guard let color = Self.backgroundColor(for: decoration.kind) else { continue }
            color.setFill()
            for rect in segments(for: decoration.range, rows: rows) {
                switch decoration.kind {
                case .agentAdded, .agentRemoved, .agentModified, .gitAdded, .gitModified, .gitRemoved:
                    NSRect(x: gutterWidth, y: rect.minY, width: textArea.width, height: rect.height).fill()
                default:
                    NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 1), xRadius: 2, yRadius: 2).fill()
                }
            }
        }
    }

    private func drawDecorationForegrounds(rows: [NativeDrawRow]) {
        guard let first = rows.first, let last = rows.last, model.decorations.count > 0 else { return }
        let visible = TextSpan(lower: first.absoluteStart, upper: last.absoluteEnd)
        for decoration in model.decorations.intersecting(visible) {
            guard let color = Self.squiggleColor(for: decoration.kind) else { continue }
            for rect in segments(for: decoration.range, rows: rows) {
                if case .link = decoration.kind { drawUnderline(rect, color: color) } else { drawSquiggle(rect, color: color) }
            }
        }
    }

    private func drawMarkedText(rows: [NativeDrawRow]) {
        guard let marked = composition, marked.length > 0 else { return }
        let color = theme.foreground
        for rect in segments(for: TextSpan(location: marked.location, length: marked.length), rows: rows) { drawUnderline(rect, color: color) }
    }

    private func drawUnderline(_ rect: CGRect, color: NSColor) {
        color.setFill()
        NSRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 1).fill()
    }

    /// 波浪线(诊断)。
    private func drawSquiggle(_ rect: CGRect, color: NSColor) {
        let path = NSBezierPath()
        let baseY = rect.maxY - 2.5
        var x = rect.minX
        path.move(to: NSPoint(x: x, y: baseY))
        var up = true
        while x < rect.maxX {
            x = min(x + 2, rect.maxX)
            path.line(to: NSPoint(x: x, y: baseY + (up ? -1.5 : 0)))
            up.toggle()
        }
        color.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func backgroundColor(for kind: DecorationKind) -> NSColor? {
        switch kind {
        case .findMatch: return NSColor(OMColors.warning).withAlphaComponent(0.28)
        case .findCurrent: return NSColor(OMColors.warning).withAlphaComponent(0.55)
        case .wordHighlight, .selectionMatch: return NSColor(OMColors.accent).withAlphaComponent(0.16)
        case .wordHighlightWrite: return NSColor(OMColors.accent).withAlphaComponent(0.26)
        case .bracketMatch: return NSColor(OMColors.accent).withAlphaComponent(0.30)
        case .agentAdded, .gitAdded: return NSColor(OMColors.diffAdded).withAlphaComponent(0.16)
        case .agentRemoved, .gitRemoved: return NSColor(OMColors.diffRemoved).withAlphaComponent(0.16)
        case .agentModified, .gitModified: return NSColor(OMColors.warning).withAlphaComponent(0.14)
        case .snippetStop: return NSColor(OMColors.accent).withAlphaComponent(0.12)
        case .snippetStopActive: return NSColor(OMColors.accent).withAlphaComponent(0.26)
        default: return nil
        }
    }

    static func squiggleColor(for kind: DecorationKind) -> NSColor? {
        switch kind {
        case .diagnosticError: return NSColor(OMColors.danger)
        case .diagnosticWarning: return NSColor(OMColors.warning)
        case .diagnosticInfo: return NSColor(OMColors.accent)
        case .diagnosticHint: return NSColor(OMColors.tertiaryText)
        case .link: return NSColor(OMColors.link)
        default: return nil
        }
    }

    // MARK: 行号栏

    private func drawGutter(rows: [NativeDrawRow]) {
        theme.gutterBackground.setFill()
        NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height).fill()
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let normal: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: theme.gutterForeground]
        let current: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: theme.foreground]
        let caretLine = model.document.snapshot.line(containing: model.selections.primary.head)
        let digit = ("0" as NSString).size(withAttributes: normal)
        for item in rows where item.rowInLine == 0 {
            let label = String(item.line + 1) as NSString
            let width = digit.width * CGFloat(label.length)
            let x = gutterWidth - foldColumnWidth - 8 - width
            label.draw(at: NSPoint(x: x, y: item.y + (lineHeight - digit.height) / 2), withAttributes: item.line == caretLine ? current : normal)
            let height = lineHeight * CGFloat(model.lineMap.wrapRows(ofLine: item.line))
            if let marker = lineMarkers[item.line] {
                Self.markerColor(marker).setFill()
                NSRect(x: 0, y: item.y, width: 3, height: height).fill()
            }
            if let severity = diagnosticLines[item.line] {
                CodeEditorView.color(for: severity).setFill()
                NSBezierPath(ovalIn: NSRect(x: 6, y: item.y + (lineHeight - 6) / 2, width: 6, height: 6)).fill()
            }
        }
    }

    static func markerColor(_ marker: LineMarker) -> NSColor {
        switch marker {
        case .added: return NSColor(OMColors.success)
        case .removed: return NSColor(OMColors.danger)
        case .modified: return NSColor(OMColors.warning)
        case .agent: return NSColor(OMColors.accent)
        }
    }

    // MARK: 滚动条

    /// 垂直滚动条拇指矩形;内容不超出时返回 nil。
    func verticalThumbRect() -> CGRect? {
        let maxY = maxScrollY
        guard maxY > 0 else { return nil }
        let track = bounds.height
        let total = maxY + bounds.height
        let length = max(28, track * bounds.height / total)
        let position = (track - length) * scrollY / maxY
        return CGRect(x: bounds.width - 10, y: position, width: 10, height: length)
    }

    /// 水平滚动条拇指矩形。
    func horizontalThumbRect() -> CGRect? {
        let maxX = maxScrollX
        guard maxX > 0 else { return nil }
        let track = textArea.width
        let total = maxX + textArea.width
        let length = max(28, track * textArea.width / total)
        let position = (track - length) * scrollX / maxX
        return CGRect(x: gutterWidth + position, y: bounds.height - 10, width: length, height: 10)
    }

    private func drawScrollbars() {
        guard ProcessInfo.processInfo.systemUptime < scrollbarVisibleUntil || scrollbarDrag != nil else { return }
        let color = NSColor(scrollbarDrag != nil ? OMColors.scrollThumbActive : OMColors.scrollThumb)
        color.setFill()
        if let thumb = verticalThumbRect() {
            NSBezierPath(roundedRect: thumb.insetBy(dx: 2, dy: 1), xRadius: 3, yRadius: 3).fill()
        }
        if let thumb = horizontalThumbRect() {
            NSBezierPath(roundedRect: thumb.insetBy(dx: 1, dy: 2), xRadius: 3, yRadius: 3).fill()
        }
    }

    /// 显示滚动条,空闲 1 秒后隐藏。
    func showScrollbars() {
        scrollbarVisibleUntil = ProcessInfo.processInfo.systemUptime + 1.0
        scrollbarHideTask?.cancel()
        scrollbarHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_050))
            guard !Task.isCancelled, let self else { return }
            if self.scrollbarDrag == nil { self.needsDisplay = true }
        }
    }
}
