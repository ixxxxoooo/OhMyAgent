// @author ygw
// 侧栏分隔条增强:双击分隔条恢复该侧栏的默认宽度。
// 拖拽缩放由原生 NavigationSplitView / inspector 提供;这里只监听双击(不拦截事件,不影响拖拽)。

import AppKit
import OMLog
import SwiftUI
import WorkbenchKit

/// 安装在工作台背景中的双击监听器。
struct PanelDividerReset: NSViewRepresentable {
    /// 双击命中某侧分隔条时回调(调用方负责写入默认宽度)
    let onReset: (PanelSide) -> Void
    /// 当前左右栏是否显示(两列布局时用于判别)
    let visibility: () -> (left: Bool, right: Bool)

    func makeNSView(context: Context) -> ResetView {
        let view = ResetView()
        view.onReset = onReset
        view.visibility = visibility
        return view
    }

    func updateNSView(_ nsView: ResetView, context: Context) {
        nsView.onReset = onReset
        nsView.visibility = visibility
    }

    @MainActor
    final class ResetView: NSView {
        var onReset: ((PanelSide) -> Void)?
        var visibility: (() -> (left: Bool, right: Bool))?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        /// 处理鼠标按下:双击且落在分隔条上 → 通知重置,并把分隔条移到默认位置。
        private func handle(_ event: NSEvent) {
            guard event.clickCount == 2, let window, event.window === window,
                  let split = Self.findSplitView(in: window.contentView) else { return }
            let point = split.convert(event.locationInWindow, from: nil)
            guard split.bounds.contains(point) else { return }
            let columns = split.arrangedSubviews.map {
                PanelColumn(minX: $0.frame.minX, maxX: $0.frame.maxX, hidden: $0.isHidden || split.isSubviewCollapsed($0))
            }
            let state: (left: Bool, right: Bool) = visibility?() ?? (left: true, right: false)
            guard let side = PanelDividers.side(at: point.x, columns: columns, leftVisible: state.left, rightVisible: state.right) else { return }
            Log.app.info("双击分隔条,恢复默认宽度", ["side": side == .left ? "left" : "right"])
            onReset?(side)
            // 同步移动原生分隔条
            let total = split.bounds.width
            if side == .left {
                split.setPosition(PanelMetrics.leftDefault, ofDividerAt: 0)
            } else if columns.count >= 2 {
                split.setPosition(total - PanelMetrics.rightDefault - split.dividerThickness, ofDividerAt: columns.count - 2)
            }
        }

        /// 在视图树中找到承载三栏的 NSSplitView(取第一个竖向分隔、子视图 ≥ 2 的)。
        private static func findSplitView(in view: NSView?) -> NSSplitView? {
            guard let view else { return nil }
            if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 2 { return split }
            for sub in view.subviews {
                if let found = findSplitView(in: sub) { return found }
            }
            return nil
        }
    }
}
