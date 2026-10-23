// @author ixxxxoooo
// 编辑器右侧缩略图(minimap):按语法色画字符块(对照 VS Code / Cursor 的 blocks 渲染),叠加视口滑块;点击或拖动滚动编辑器。
// 语法片段由高亮引擎按采样行批量提供(视口外的文本存储没有前景色,不能直接读属性)。

import AppKit

/// 缩略图视图。
@MainActor
final class EditorMinimapView: NSView {
    /// 宽度
    static let width: CGFloat = 84
    private static let rowHeight: CGFloat = 2
    /// 每行最多扫描的字符数
    private static let maxScan = 140
    /// 每行最多绘制的列数(超出截断)
    private static let maxColumns = 120
    unowned let editor: CodeEditorView
    private var dragging = false

    init(editor: CodeEditorView) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// 可绘制的像素行数。
    private var rowCount: Int { max(Int(bounds.height / Self.rowHeight), 1) }

    /// 缩略图内容高度:行数不超过可用行数时按行铺,否则压缩到整个视图高度。
    private var contentHeight: CGFloat {
        let lines = editor.lineIndex.lineCount
        return lines <= rowCount ? CGFloat(lines) * Self.rowHeight : bounds.height
    }

    // MARK: 语法片段

    /// 按采样行取回的语法片段:`lines[i]` 行的片段,位置为相对行首的偏移(编辑后短暂沿用旧结果,颜色不闪)。
    private struct LineSyntax {
        let rows: Int
        let lineCount: Int
        let spans: [[SyntaxSpan]]
    }

    private var syntax: LineSyntax?
    /// 语法片段修订号:每次取回加一,条形缓存据此失效
    private(set) var syntaxRevision = 0
    private var syntaxTask: Task<Void, Never>?
    /// 正在取的采样(行数、总行数),避免重复发起
    private var pendingSyntax: (rows: Int, lineCount: Int)?

    /// 高亮引擎已与文本同步:按当前采样重取语法片段。
    func syntaxDidChange() {
        pendingSyntax = nil
        fetchSyntax()
    }

    /// 采样与已有/在途结果不一致时发起取片段。
    private func fetchSyntaxIfNeeded() {
        let rows = rowCount
        let lineCount = editor.lineIndex.lineCount
        if let syntax, syntax.rows == rows, syntax.lineCount == lineCount { return }
        if let pendingSyntax, pendingSyntax.rows == rows, pendingSyntax.lineCount == lineCount { return }
        fetchSyntax()
    }

    /// 在高亮引擎(后台 actor)里按采样行批量取片段,完成后重画。
    private func fetchSyntax() {
        guard editor.lineIndexIsLive, editor.lineIndex.lineCount > 0, bounds.height > 0 else { return }
        let rows = rowCount
        let index = editor.lineIndex
        let lines = EditorScopes.minimapLines(lineCount: index.lineCount, rows: rows)
        let ranges = lines.map { line -> NSRange in
            guard let range = index.range(ofLine: line) else { return NSRange(location: 0, length: 0) }
            return NSRange(location: range.location, length: min(range.length, Self.maxScan))
        }
        pendingSyntax = (rows, index.lineCount)
        syntaxTask?.cancel()
        let engine = editor.engine
        syntaxTask = Task { [weak self] in
            let found = await engine.spans(inEach: ranges)
            guard !Task.isCancelled, let self else { return }
            let relative = zip(ranges, found).map { range, spans in
                spans.map { SyntaxSpan(location: $0.location - range.location, length: $0.length, kind: $0.kind) }
            }
            self.syntax = LineSyntax(rows: rows, lineCount: index.lineCount, spans: relative)
            self.pendingSyntax = nil
            self.syntaxRevision &+= 1
            self.needsDisplay = true
        }
    }

    // MARK: 绘制

    /// 条形图缓存的键:尺寸、缩放、外观、配色、文本与语法修订任一变化都要重画。
    private struct BarsKey: Equatable {
        let size: NSSize
        let scale: CGFloat
        let appearance: NSAppearance.Name
        let revision: Int
        let syntaxRevision: Int
        let lineCount: Int
        let foreground: NSColor
        let colors: [SyntaxKind: NSColor]
    }

    /// 已渲染的条形位图与它对应的键(滚动、滑块移动不改变条形,直接复用)
    private var barsCache: (key: BarsKey, image: NSBitmapImageRep)?
    /// 文本修订号:文本存储每次字符编辑加一,条形缓存据此失效
    private(set) var contentRevision = 0

    /// 文本内容变化:条形缓存失效并重画。
    func contentDidChange() {
        contentRevision &+= 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard editor.lineIndexIsLive else { return }
        let theme = editor.theme
        barsImage()?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        // 视口滑块
        let slider = sliderRect()
        theme.foreground.withAlphaComponent(0.10).setFill()
        slider.fill(using: .sourceOver)
        theme.foreground.withAlphaComponent(0.22).setStroke()
        NSBezierPath(rect: slider.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    /// 取条形位图:键未变时复用缓存,否则重新渲染;语法片段与当前采样不符时顺带发起重取。
    /// - Parameter scale: 位图缩放;nil 时取窗口的 backingScaleFactor
    /// - Returns: 位图;行索引未就绪或尺寸为空时 nil
    func barsImage(scale: CGFloat? = nil) -> NSBitmapImageRep? {
        guard editor.lineIndexIsLive else { return nil }
        fetchSyntaxIfNeeded()
        let scale = scale ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let theme = editor.theme
        let key = BarsKey(size: bounds.size, scale: scale, appearance: effectiveAppearance.name, revision: contentRevision,
                          syntaxRevision: syntaxRevision, lineCount: editor.lineIndex.lineCount,
                          foreground: theme.foreground, colors: theme.colors)
        if barsCache?.key != key {
            // 动态主题色按本视图的外观解析(测试与离屏渲染时没有当前绘制外观)
            var image: NSBitmapImageRep?
            effectiveAppearance.performAsCurrentDrawingAppearance { image = renderBars(key) }
            barsCache = image.map { (key, $0) }
        }
        return barsCache?.image
    }

    /// 把整张条形图渲染进位图:每个采样行按语法色画字符块,空白不画。
    /// - Parameter key: 本次渲染对应的键(尺寸与缩放)
    /// - Returns: 位图;尺寸为空或创建失败时 nil
    private func renderBars(_ key: BarsKey) -> NSBitmapImageRep? {
        let pixelsWide = Int((key.size.width * key.scale).rounded(.up))
        let pixelsHigh = Int((key.size.height * key.scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // 必须先设点尺寸再建上下文:上下文按此换算缩放,之后再设则按像素坐标绘制(条形缩一半并落到下半部)
        rep.size = key.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let index = editor.lineIndex
        let ns = editor.textView.string as NSString
        let lines = EditorScopes.minimapLines(lineCount: index.lineCount, rows: rowCount)
        // 采样一致时用对应行的片段;行数变化(插入/删除行)后等引擎同步再上色
        let lineSpans = syntax.flatMap { $0.rows == rowCount && $0.lineCount == index.lineCount ? $0.spans : nil }
        let painter = MinimapLinePainter(foreground: key.foreground.withAlphaComponent(0.45),
                                         colors: key.colors.mapValues { $0.withAlphaComponent(0.85) },
                                         columnWidth: (Self.width - 10) / CGFloat(Self.maxColumns),
                                         maxScan: Self.maxScan, maxColumns: Self.maxColumns)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        // 位图坐标系 y 向上:翻转成与视图一致的 y 向下
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: key.size.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        for (row, line) in lines.enumerated() {
            guard let range = index.range(ofLine: line), range.length > 0, NSMaxRange(range) <= ns.length else { continue }
            let spans = lineSpans.flatMap { row < $0.count ? $0[row] : nil } ?? []
            painter.paint(ns, range: range, spans: spans, y: CGFloat(row) * Self.rowHeight, height: Self.rowHeight - 0.5)
        }
        return rep
    }

    /// 视口滑块在缩略图里的位置。
    private func sliderRect() -> NSRect {
        let scroll = editor.scrollView
        let documentHeight = max(editor.textView.frame.height, 1)
        let visible = scroll.contentView.bounds
        let content = contentHeight
        let y = visible.minY / documentHeight * content
        let height = max(min(visible.height / documentHeight * content, content), 12)
        return NSRect(x: 0, y: min(y, max(content - height, 0)), width: bounds.width, height: height)
    }

    // MARK: 交互

    override func mouseDown(with event: NSEvent) {
        dragging = true
        scroll(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        scroll(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { dragging = false }

    /// 把点击位置对应的文档位置滚动到视口中央。
    private func scroll(to point: NSPoint) {
        let content = max(contentHeight, 1)
        let fraction = min(max(point.y / content, 0), 1)
        let scroll = editor.scrollView
        let documentHeight = editor.textView.frame.height
        let visibleHeight = scroll.contentView.bounds.height
        let target = min(max(fraction * documentHeight - visibleHeight / 2, 0), max(documentHeight - visibleHeight, 0))
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// 缩略图单行绘制:把一行切成「同色、连续非空白」的字符块,每块画一个矩形。
@MainActor
private struct MinimapLinePainter {
    let foreground: NSColor
    let colors: [SyntaxKind: NSColor]
    let columnWidth: CGFloat
    let maxScan: Int
    let maxColumns: Int

    /// 绘制一行。
    /// - Parameters:
    ///   - ns: 全文
    ///   - range: 该行范围(含换行符)
    ///   - spans: 该行的语法片段(位置相对行首;按文档顺序,重叠时后者覆盖前者)
    ///   - y: 行顶坐标
    ///   - height: 块高度
    func paint(_ ns: NSString, range: NSRange, spans: [SyntaxSpan], y: CGFloat, height: CGFloat) {
        let limit = min(range.length, maxScan)
        var kinds = [SyntaxKind?](repeating: nil, count: limit)
        for span in spans {
            let start = max(span.location, 0)
            let end = min(span.location + span.length, limit)
            if start < end { for offset in start..<end { kinds[offset] = span.kind } }
        }
        var column = 0
        var runStart = -1
        var runKind: SyntaxKind?
        /// 结束当前字符块并画出
        func flush() {
            guard runStart >= 0 else { return }
            let color = runKind.flatMap { colors[$0] } ?? foreground
            color.setFill()
            let x = 5 + CGFloat(runStart) * columnWidth
            NSRect(x: x, y: y, width: max(CGFloat(column - runStart) * columnWidth, 1), height: height).fill(using: .sourceOver)
            runStart = -1
        }
        for offset in 0..<limit where column < maxColumns {
            let unit = ns.character(at: range.location + offset)
            if unit == 32 || unit == 9 || unit == 10 || unit == 13 {
                flush()
                column += unit == 9 ? 4 : (unit == 32 ? 1 : 0)
                continue
            }
            let kind = kinds[offset]
            if runStart >= 0, kind != runKind { flush() }
            if runStart < 0 { runStart = column; runKind = kind }
            column += 1
        }
        column = min(column, maxColumns)
        flush()
    }
}
