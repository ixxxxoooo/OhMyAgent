// @author ixxxxoooo
// 统一的分栏拖动手柄:1pt 发丝线 + 9pt AppKit 命中区。
// - 光标交给系统:`NSTrackingArea(.cursorUpdate)` + `resetCursorRects`,不再手动 `NSCursor.push/pop`(进出过快会不配对,导致光标不变);
// - 悬停与拖动时显示 2pt 强调色线,给出明确的「可拖动」反馈;
// - 拖动用屏幕坐标计算位移(面板自身在移动,窗口坐标不稳定),松手/取消都保证回调 `onEnded`;
// - 项目栏、右栏、中栏分屏条与 Files 工作区内部分栏共用这一个组件。

import AppKit
import DesignSystem
import SwiftUI

/// 分栏拖动手柄。
struct OMSplitHandle: View {
    /// 手柄方向
    enum Axis: Equatable {
        /// 竖线(分隔左右两栏),拖动方向为水平
        case vertical
        /// 横线(分隔上下两栏),拖动方向为垂直
        case horizontal

        /// 对应的系统光标。
        var cursor: NSCursor { self == .vertical ? .resizeLeftRight : .resizeUpDown }
    }

    /// 命中区厚度(垂直于手柄方向)
    static let hitThickness: CGFloat = 9
    /// 发丝线厚度
    static let lineThickness: CGFloat = 1
    /// 悬停/拖动时强调线厚度
    static let activeThickness: CGFloat = 2

    let axis: Axis
    /// 开始拖动
    var onBegan: () -> Void = {}
    /// 拖动中:沿手柄法线方向的累计位移(竖线为向右为正,横线为向下为正)
    var onChanged: (CGFloat) -> Void = { _ in }
    /// 结束拖动(松手或取消)
    var onEnded: () -> Void = {}
    /// 双击(可选)
    var onDoubleClick: (() -> Void)?

    @State private var hovering = false
    @State private var dragging = false

    private var horizontalAxis: Bool { axis == .vertical }

    var body: some View {
        Rectangle()
            .fill(OMColors.hairline)
            .frame(width: horizontalAxis ? Self.lineThickness : nil, height: horizontalAxis ? nil : Self.lineThickness)
            .overlay {
                // 强调线叠在发丝线上,居中;只在悬停/拖动时出现
                Rectangle()
                    .fill(OMColors.accent.opacity(dragging ? 0.55 : 0.35))
                    .frame(width: horizontalAxis ? Self.activeThickness : nil, height: horizontalAxis ? nil : Self.activeThickness)
                    .opacity(hovering || dragging ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.12), value: hovering || dragging)
            }
            .overlay {
                SplitHandleHitArea(
                    axis: axis,
                    onHover: { hovering = $0 },
                    onBegan: { dragging = true; onBegan() },
                    onChanged: onChanged,
                    onEnded: { dragging = false; onEnded() },
                    onDoubleClick: onDoubleClick
                )
                .frame(width: horizontalAxis ? Self.hitThickness : nil, height: horizontalAxis ? nil : Self.hitThickness)
            }
    }

    /// 由屏幕坐标起止点计算沿法线方向的位移。
    /// - Parameters:
    ///   - start: 按下时的屏幕坐标
    ///   - current: 当前屏幕坐标
    ///   - axis: 手柄方向
    /// - Returns: 竖线为 `Δx`;横线为向下为正的位移(屏幕坐标 y 向上,故取负)
    static func translation(from start: CGPoint, to current: CGPoint, axis: Axis) -> CGFloat {
        axis == .vertical ? current.x - start.x : -(current.y - start.y)
    }
}

/// 命中区:AppKit 视图负责光标、悬停与拖动事件。
private struct SplitHandleHitArea: NSViewRepresentable {
    let axis: OMSplitHandle.Axis
    let onHover: (Bool) -> Void
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> SplitHandleNSView {
        let view = SplitHandleNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: SplitHandleNSView, context: Context) { apply(to: view) }

    private func apply(to view: SplitHandleNSView) {
        view.axis = axis
        view.onHover = onHover
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onDoubleClick = onDoubleClick
    }
}

/// 分栏手柄的 AppKit 实现。
final class SplitHandleNSView: NSView {
    var axis: OMSplitHandle.Axis = .vertical {
        didSet { if oldValue != axis { window?.invalidateCursorRects(for: self) } }
    }
    var onHover: (Bool) -> Void = { _ in }
    var onBegan: () -> Void = {}
    var onChanged: (CGFloat) -> Void = { _ in }
    var onEnded: () -> Void = {}
    var onDoubleClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    /// 按下时的屏幕坐标(`nil` 表示未在拖动)
    private var dragStart: CGPoint?
    /// 是否已越过起拖阈值并回调过 `onBegan`(单击/双击不触发拖动回调)
    private var began = false
    /// 本次按下是否为第二次连击(仅在没有发生拖动的松手时才算双击)
    private var pendingDoubleClick = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis.cursor)
    }

    override func cursorUpdate(with event: NSEvent) { axis.cursor.set() }

    override func mouseEntered(with event: NSEvent) {
        axis.cursor.set()
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        // 拖动中鼠标可能移出命中区,保持强调线由 dragging 状态负责
        onHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        // 双击放到松手时判定:连续两次拖动(第二次按下系统计为 clickCount=2)不应被当作双击吞掉,否则第二次拖不动
        pendingDoubleClick = event.clickCount >= 2
        dragStart = NSEvent.mouseLocation
        began = false
        axis.cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        axis.cursor.set()
        let delta = OMSplitHandle.translation(from: start, to: NSEvent.mouseLocation, axis: axis)
        if !began {
            guard abs(delta) >= 1 else { return }
            began = true
            onBegan()
        }
        onChanged(delta)
    }

    override func mouseUp(with event: NSEvent) {
        let isDoubleClick = pendingDoubleClick && !began && dragStart != nil
        pendingDoubleClick = false
        finishDrag()
        if isDoubleClick { onDoubleClick?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 视图被移出窗口(如面板收起)时,若仍在拖动,补一次结束回调,避免拖动状态悬空
        if window == nil { finishDrag() }
    }

    /// 结束拖动并回调(幂等)。
    private func finishDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        guard began else { return }
        began = false
        onEnded()
    }
}
