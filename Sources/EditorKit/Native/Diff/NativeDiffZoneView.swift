// @author ixxxxoooo
// Diff 视图的 View Zone 内容:顶部的块头条(块标题 + 块级操作按钮)、其下的「已删除行」或对齐用的空白占位。
// 并排 Diff、内联 Diff 与 Agent 行内改动审阅共用。

import AppKit
import DesignSystem

/// 块级操作(暂存/放弃/接受/拒绝…)。
public struct NativeDiffAction: Identifiable {
    public var id: String { title }
    public var title: String
    /// 参数为块 id。
    public var perform: (Int) -> Void

    public init(title: String, perform: @escaping (Int) -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// 头条里的一个文字按钮。
@MainActor
final class NativeDiffActionButton: NSView {
    let title: String
    var onClick: (() -> Void)?
    private var hovered = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11 * OMScale.ui, weight: .medium), .foregroundColor: NSColor(hovered ? OMColors.accentText : OMColors.accent)]
    }

    var preferredWidth: CGFloat { ceil((title as NSString).size(withAttributes: attributes).width) + 14 }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor(OMColors.hoverFill).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: OMRadius.tag, yRadius: OMRadius.tag).fill()
        }
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
}

/// View Zone 内容视图。
@MainActor
final class NativeDiffZoneView: NSView {
    /// 头条高度。
    static let headerHeight: CGFloat = 22

    struct Header {
        var title: String
        var actions: [(title: String, handler: () -> Void)]
    }

    private let header: Header?
    private let deleted: [String]
    private let padHeight: CGFloat
    private let editorFont: NSFont
    private let lineHeight: CGFloat
    private let textInset: CGFloat
    private var buttons: [NativeDiffActionButton] = []

    /// - Parameters:
    ///   - header: 头条(没有则不画)
    ///   - deleted: 要展示的已删除行(内联模式)
    ///   - padHeight: 对齐用的空白高度(并排模式)
    ///   - font: 编辑器字体
    ///   - lineHeight: 行高
    ///   - textInset: 文本左内边距
    init(header: Header?, deleted: [String], padHeight: CGFloat, font: NSFont, lineHeight: CGFloat, textInset: CGFloat) {
        self.header = header
        self.deleted = deleted
        self.padHeight = padHeight
        self.editorFont = font
        self.lineHeight = lineHeight
        self.textInset = textInset
        super.init(frame: .zero)
        for action in header?.actions ?? [] {
            let button = NativeDiffActionButton(title: action.title)
            button.onClick = action.handler
            addSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var right = bounds.width - 8
        for button in buttons.reversed() {
            let width = button.preferredWidth
            button.frame = NSRect(x: right - width, y: 0, width: width, height: Self.headerHeight)
            right -= width + 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        var top: CGFloat = 0
        if let header {
            NSColor(OMColors.subtleFill).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight).fill()
            NSColor(OMColors.hairline).setFill()
            NSRect(x: 0, y: Self.headerHeight - 0.5, width: bounds.width, height: 0.5).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10.5 * OMScale.ui, weight: .regular),
                                                         .foregroundColor: NSColor(OMColors.secondaryText)]
            let size = (header.title as NSString).size(withAttributes: attrs)
            (header.title as NSString).draw(at: NSPoint(x: textInset, y: (Self.headerHeight - size.height) / 2), withAttributes: attrs)
            top = Self.headerHeight
        }
        if !deleted.isEmpty {
            NSColor(OMColors.diffRemoved).withAlphaComponent(0.16).setFill()
            NSRect(x: 0, y: top, width: bounds.width, height: CGFloat(deleted.count) * lineHeight).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: editorFont, .foregroundColor: NSColor(OMColors.secondaryText)]
            for (index, line) in deleted.enumerated() {
                let y = top + CGFloat(index) * lineHeight
                let size = (line as NSString).size(withAttributes: attrs)
                (line as NSString).draw(at: NSPoint(x: textInset, y: y + (lineHeight - size.height) / 2), withAttributes: attrs)
            }
        } else if padHeight > 0 {
            NSColor(OMColors.subtleFill).setFill()
            NSRect(x: 0, y: top, width: bounds.width, height: padHeight).fill()
        }
    }
}
