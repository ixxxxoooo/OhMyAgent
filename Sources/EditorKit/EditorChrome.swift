// @author ixxxxoooo
// 编辑器的 IDE 外围视图:右侧缩略图(minimap)与顶部粘性滚动(sticky scroll)。
// 两者都只读取编辑器的行索引、文本与滚动位置,不改动文本布局。

import AppKit
import DesignSystem

/// 要显示哪些 IDE 外围视图。
public struct EditorChrome: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// 右侧缩略图
    public static let minimap = EditorChrome(rawValue: 1 << 0)
    /// 顶部粘性滚动
    public static let stickyScroll = EditorChrome(rawValue: 1 << 1)
}

/// 偏好键(设置 → 编辑器 → 代码编辑)。
public extension EditorBehaviorPrefs {
    /// 缩略图开关的键
    static let minimapKey = "editor.minimap"
    /// 粘性滚动开关的键
    static let stickyScrollKey = "editor.stickyScroll"
    /// 是否显示缩略图(默认开)。
    static var minimap: Bool { UserDefaults.standard.object(forKey: minimapKey) as? Bool ?? true }
    /// 是否显示粘性滚动(默认开)。
    static var stickyScroll: Bool { UserDefaults.standard.object(forKey: stickyScrollKey) as? Bool ?? true }
}

/// 缩略图:每行画一条与缩进、长度成比例的细条,叠加当前视口滑块;点击或拖动滚动编辑器。
@MainActor
final class EditorMinimapView: NSView {
    /// 宽度
    static let width: CGFloat = 84
    private static let rowHeight: CGFloat = 2
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

    /// 缩略图内容高度:行数不超过可用行数时按行铺,否则压缩到整个视图高度。
    private var contentHeight: CGFloat {
        let rows = Int(bounds.height / Self.rowHeight)
        let lines = editor.lineIndex.lineCount
        return lines <= rows ? CGFloat(lines) * Self.rowHeight : bounds.height
    }

    override func draw(_ dirtyRect: NSRect) {
        guard editor.lineIndexIsLive else { return }
        let theme = editor.theme
        let index = editor.lineIndex
        let ns = editor.textView.string as NSString
        let rows = max(Int(bounds.height / Self.rowHeight), 1)
        let lines = EditorScopes.minimapLines(lineCount: index.lineCount, rows: rows)
        let scale = (Self.width - 10) / 120
        let bar = theme.foreground.withAlphaComponent(0.30)
        let dim = theme.foreground.withAlphaComponent(0.14)
        for (row, line) in lines.enumerated() {
            let y = CGFloat(row) * Self.rowHeight
            guard y + Self.rowHeight >= dirtyRect.minY, y <= dirtyRect.maxY, let range = index.range(ofLine: line), range.length > 0, NSMaxRange(range) <= ns.length else { continue }
            // 缩进与可见长度(只扫描前 140 个字符)
            let limit = min(range.length, 140)
            var indent = 0
            var cursor = 0
            while cursor < limit {
                let unit = ns.character(at: range.location + cursor)
                if unit == 32 { indent += 1 } else if unit == 9 { indent += 4 } else { break }
                cursor += 1
            }
            let end = range.location + range.length
            var contentLength = limit - cursor
            if range.length <= 140, end > 0, ns.character(at: end - 1) == 10 { contentLength -= 1 }
            guard contentLength > 0 else { continue }
            let comment = cursor + 1 < limit && ns.character(at: range.location + cursor) == 47 && ns.character(at: range.location + cursor + 1) == 47
            (comment ? dim : bar).setFill()
            let x = 5 + CGFloat(min(indent, 60)) * scale
            let width = max(CGFloat(min(contentLength, 120)) * scale, 2)
            NSRect(x: x, y: y, width: width, height: Self.rowHeight - 0.5).fill(using: .sourceOver)
        }
        // 视口滑块
        let slider = sliderRect()
        theme.foreground.withAlphaComponent(0.10).setFill()
        slider.fill(using: .sourceOver)
        theme.foreground.withAlphaComponent(0.22).setStroke()
        NSBezierPath(rect: slider.insetBy(dx: 0.5, dy: 0.5)).stroke()
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

/// 粘性滚动条:顶部叠放当前视口第一行所在的外层块头行(最多 3 行),点击跳到该行。
@MainActor
final class EditorStickyView: NSView {
    unowned let editor: CodeEditorView
    /// 当前显示的块头行号(0 起始)
    private(set) var lines: [Int] = []

    init(editor: CodeEditorView) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// 每行高度(与编辑器行高一致)。
    private var rowHeight: CGFloat { max(editor.theme.paragraphStyle.minimumLineHeight, 16) }

    /// 按当前滚动位置重算要显示的块头;结果变化才重绘。
    func refresh() {
        guard editor.lineIndexIsLive, editor.lineIndex.lineCount > 1 else { clear(); return }
        let textView = editor.textView
        let visible = editor.scrollView.contentView.bounds
        let origin = textView.textContainerOrigin
        let offset = textView.characterIndexForInsertion(at: NSPoint(x: origin.x + 1, y: visible.minY + origin.y + 1))
        let topLine = editor.lineIndex.line(containing: min(offset, editor.lineIndex.length))
        let ns = textView.string as NSString
        let index = editor.lineIndex
        let found = EditorScopes.enclosing(topLine: topLine, lineCount: index.lineCount) { line in
            guard let range = index.range(ofLine: line), range.length < 400 else { return nil }
            return ns.substring(with: range)
        }
        guard found != lines else { return }
        lines = found
        isHidden = found.isEmpty
        needsDisplay = true
        invalidateIntrinsicContentSize()
        editor.stickyHeightDidChange(CGFloat(found.count) * rowHeight)
    }

    private func clear() {
        guard !lines.isEmpty else { return }
        lines = []
        isHidden = true
        editor.stickyHeightDidChange(0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = editor.theme
        theme.background.setFill()
        bounds.fill(using: .sourceOver)
        guard let storage = editor.textView.textStorage else { return }
        let index = editor.lineIndex
        // 文本左边界:取文本视图里第一个字符的横坐标换算到本视图,保证与正文对齐
        let textView = editor.textView
        let padding = textView.textContainer?.lineFragmentPadding ?? 0
        let textX = textView.convert(NSPoint(x: textView.textContainerOrigin.x + padding, y: 0), to: self).x
        for (row, line) in lines.enumerated() {
            guard let range = index.range(ofLine: line) else { continue }
            var trimmed = range
            if trimmed.length > 0, (storage.string as NSString).character(at: NSMaxRange(range) - 1) == 10 { trimmed.length -= 1 }
            let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: trimmed))
            text.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: text.length))
            let y = CGFloat(row) * rowHeight
            text.draw(at: NSPoint(x: textX, y: y + (rowHeight - theme.font.pointSize * 1.25) / 2))
        }
        theme.foreground.withAlphaComponent(0.14).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill(using: .sourceOver)
    }

    override func mouseDown(with event: NSEvent) {
        let row = Int(convert(event.locationInWindow, from: nil).y / rowHeight)
        guard lines.indices.contains(row) else { return }
        editor.goToLine(lines[row] + 1)
    }
}
