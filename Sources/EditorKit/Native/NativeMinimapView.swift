// @author ixxxxoooo
// 缩略图:把全文按「1 点 / 列、2 点 / 行」缩小绘制,带可拖动的视口滑块。
// 每行只构建一次「色块游程」并缓存,绘制时只画可见的缩略行;编辑后防抖失效,避免输入时每键重建。

import AppKit
import CoreGraphics
import EditorCore

@MainActor
final class NativeMinimapView: NSView {
    /// 缩略图宽度(点)。
    static let width: CGFloat = 84
    /// 每个缩略行的高度、每列宽度(点)。
    static let rowHeight: CGFloat = 2
    static let columnWidth: CGFloat = 1
    /// 每行最多取的列数。
    static let maxColumns = 80

    /// 一段连续着色的非空白字符。
    private struct Run {
        var start: Int16
        var length: Int16
        var color: UInt8
    }

    private unowned let editor: OMEditorView
    private var lineRuns: [Int: [Run]] = [:]
    private var invalidateTask: Task<Void, Never>?
    private var dragging = false

    init(editor: OMEditorView) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollArea)
        setAccessibilityLabel(String(localized: "代码缩略图"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: 更新

    /// 文档变化:防抖后失效缓存并重绘。
    func documentDidChange() {
        invalidateTask?.cancel()
        invalidateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self else { return }
            self.lineRuns.removeAll(keepingCapacity: true)
            self.needsDisplay = true
        }
    }

    /// 语法/主题更新:立刻失效。
    func invalidateAll() {
        lineRuns.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    func editorDidScroll() { needsDisplay = true }

    // MARK: 几何

    private var lineCount: Int { editor.model.document.lineCount }
    private var contentHeight: CGFloat { CGFloat(lineCount) * Self.rowHeight }

    /// 缩略图自身的滚动偏移(内容高于视图时按编辑器滚动比例同步)。
    private var miniScroll: CGFloat {
        let overflow = contentHeight - bounds.height
        guard overflow > 0, editor.maxScrollY > 0 else { return 0 }
        return overflow * editor.scrollY / editor.maxScrollY
    }

    /// 某模型行在缩略图里的 y。
    private func y(ofLine line: Int) -> CGFloat { CGFloat(line) * Self.rowHeight - miniScroll }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let theme = editor.theme
        theme.background.setFill()
        // macOS 14+ 子视图默认不裁剪到自身边界:填充必须自己限制在 bounds 内,否则会盖住兄弟内容。
        dirtyRect.intersection(bounds).fill()
        let total = lineCount
        guard total > 0 else { return }
        let scroll = miniScroll
        let first = max(Int(scroll / Self.rowHeight), 0)
        let last = min(Int((scroll + bounds.height) / Self.rowHeight) + 1, total - 1)
        guard first <= last else { return }
        let palette = colorPalette()
        let left: CGFloat = 4
        // 按颜色分批,减少 CGContext 状态切换。
        var batches = [[CGRect]](repeating: [], count: palette.count)
        for line in first...last {
            let y = y(ofLine: line)
            for run in runs(forLine: line) {
                batches[Int(run.color)].append(CGRect(x: left + CGFloat(run.start) * Self.columnWidth, y: y, width: CGFloat(run.length) * Self.columnWidth, height: Self.rowHeight - 0.5))
            }
        }
        for (index, rects) in batches.enumerated() where !rects.isEmpty {
            context.setFillColor(palette[index].cgColor)
            context.fill(rects)
        }
        drawSlider(context: context, theme: theme)
    }

    /// 视口滑块。
    private func drawSlider(context: CGContext, theme: EditorTheme) {
        let rope = editor.model.document.snapshot
        guard editor.model.lineMap.totalRows > 0 else { return }
        let topLine = editor.model.lineMap.locate(row: editor.row(atY: 0)).line
        let bottomLine = editor.model.lineMap.locate(row: editor.row(atY: editor.bounds.height)).line
        _ = rope
        let y1 = y(ofLine: topLine)
        let y2 = y(ofLine: bottomLine + 1)
        let rect = CGRect(x: 0, y: y1, width: bounds.width, height: max(y2 - y1, 8))
        theme.foreground.withAlphaComponent(dragging ? 0.16 : 0.09).setFill()
        rect.fill()
    }

    /// 颜色表:0 为默认前景,其余按语法类型。
    private func colorPalette() -> [NSColor] {
        let theme = editor.theme
        var colors = [theme.foreground.withAlphaComponent(0.55)]
        for raw in 0...6 {
            guard let kind = SyntaxKind(rawValue: UInt8(raw)), let color = theme.colors[kind] else { colors.append(colors[0]); continue }
            colors.append(color.withAlphaComponent(0.8))
        }
        return colors
    }

    /// 某行的色块游程(带缓存)。
    private func runs(forLine line: Int) -> [Run] {
        if let cached = lineRuns[line] { return cached }
        let rope = editor.model.document.snapshot
        guard let range = rope.lineRange(line) else { return [] }
        let length = min(range.length, Self.maxColumns * 2)
        let units = rope.slice(TextSpan(location: range.location, length: length))
        let spans = editor.tokens.spans(intersecting: NSRange(location: range.location, length: length))
        var colors = [UInt8](repeating: 0, count: units.count)
        for span in spans {
            guard case .custom(let raw) = span.kind else { continue }
            let lower = max(span.range.location - range.location, 0)
            let upper = min(span.range.upperBound - range.location, units.count)
            guard upper > lower else { continue }
            for index in lower..<upper { colors[index] = UInt8(raw + 1) }
        }
        var result: [Run] = []
        var column = 0
        var runStart = -1
        var runColor: UInt8 = 0
        let tab = max(editor.model.metrics.tabSize, 1)
        for (index, unit) in units.enumerated() {
            let isSpace = unit == 0x20 || unit == 0x09
            if isSpace {
                if runStart >= 0 { result.append(Run(start: Int16(runStart), length: Int16(column - runStart), color: runColor)); runStart = -1 }
                column += unit == 0x09 ? tab - column % tab : 1
            } else {
                if runStart >= 0, colors[index] != runColor {
                    result.append(Run(start: Int16(runStart), length: Int16(column - runStart), color: runColor))
                    runStart = -1
                }
                if runStart < 0 { runStart = column; runColor = colors[index] }
                column += 1
            }
            if column >= Self.maxColumns { break }
        }
        if runStart >= 0 { result.append(Run(start: Int16(runStart), length: Int16(min(column, Self.maxColumns) - runStart), color: runColor)) }
        if lineRuns.count > 6_000 { lineRuns.removeAll(keepingCapacity: true) }
        lineRuns[line] = result
        return result
    }

    // MARK: 交互

    override func mouseDown(with event: NSEvent) {
        dragging = true
        scrollEditor(to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        scrollEditor(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) { editor.scrollWheel(with: event) }

    /// 把编辑器滚到「缩略图上被点位置居中」。
    private func scrollEditor(to point: CGPoint) {
        let line = min(max(Int((point.y + miniScroll) / Self.rowHeight), 0), max(lineCount - 1, 0))
        let row = editor.model.lineMap.firstRow(ofLine: line)
        let target = CGFloat(editor.model.zoneLayout.y(ofRow: row)) - editor.bounds.height / 2 + editor.lineHeight
        editor.scroll(y: target)
    }
}
