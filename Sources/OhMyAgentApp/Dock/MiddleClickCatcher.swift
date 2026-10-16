// @author ixxxxoooo
// 鼠标中键捕获:SwiftUI 没有中键手势,这里用不拦截事件的透明 NSView + 本地事件监视器实现。
// 用法:`.background(MiddleClickCatcher { … })`,中键在该视图范围内抬起时触发回调。

import AppKit
import SwiftUI

/// 中键点击捕获器(放在 `.background` 中,不影响左键点击、拖拽、悬停与右键菜单)。
struct MiddleClickCatcher: NSViewRepresentable {
    /// 中键在视图范围内抬起时回调
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.action = action
    }

    @MainActor
    final class CatcherView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        /// 透明视图不参与命中测试,所有鼠标事件原样交给下层视图。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
                // NSEvent 不是 Sendable:只让「是否吞掉」这个布尔值跨出隔离域
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { removeMonitor() }
        }

        /// 命中本视图范围内的中键抬起则触发回调。
        /// - Returns: 是否已处理(true 表示应吞掉该事件)
        private func handle(_ event: NSEvent) -> Bool {
            guard event.buttonNumber == 2, let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            action?()
            return true
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
