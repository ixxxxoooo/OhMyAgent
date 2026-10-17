// @author ixxxxoooo
// 自绘滚动条:取代系统滚动条的外观(图里偏粗的深灰条)。
// 无轨道底色;圆角细滑块(静止 6pt,悬停/拖动 9pt),颜色取主题令牌 `OMColors.scrollThumb`;
// 显隐(滚动时淡入、静止后淡出)交给 NSScrollView 的浮层滚动条机制,因此天然遵循系统「减弱动态效果」。

import AppKit
import DesignSystem

/// 细滑块滚动条。由 `ScrollbarPolicy` 装到窗口内的 `NSScrollView` 上。
@MainActor
final class OMScroller: NSScroller {
    /// 静止时滑块粗细
    static let restingThickness: CGFloat = 6
    /// 悬停或拖动时滑块粗细
    static let activeThickness: CGFloat = 9
    /// 滑块距滚动条边缘的留白
    static let edgeInset: CGFloat = 2

    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    private var themeObserver: (any NSObjectProtocol)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observeTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeTheme()
    }

    isolated deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    /// 主题切换时重绘滑块颜色。
    private func observeTheme() {
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        restingThickness + activeThickness / 2 + edgeInset
    }

    /// 无轨道:不画底槽。
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 0, knob.height > 0 else { return }
        let active = hovering || hitPart == .knob
        let thickness = active ? Self.activeThickness : Self.restingThickness
        let isVertical = bounds.height >= bounds.width
        let thumb: NSRect
        if isVertical {
            thumb = NSRect(x: bounds.maxX - thickness - Self.edgeInset, y: knob.minY + 1, width: thickness, height: max(thickness, knob.height - 2))
        } else {
            thumb = NSRect(x: knob.minX + 1, y: bounds.maxY - thickness - Self.edgeInset, width: max(thickness, knob.width - 2), height: thickness)
        }
        NSColor(active ? OMColors.scrollThumbActive : OMColors.scrollThumb).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    // MARK: 悬停跟踪

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
    }
}
