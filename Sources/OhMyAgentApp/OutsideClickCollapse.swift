// @author ixxxxoooo
// 输入框上方弹层(任务坞面板、待办卡等)的「点击外部收起」:
// 与消息编辑用的 `OutsideClickDismissCoordinator` 不同,这里不吞掉点击——点外面既收起弹层,
// 这一下点击也照常作用到被点的控件(按钮、输入框、会话区)。

import AppKit
import SwiftUI

/// 外部点击观察器:弹层展开期间安装本地鼠标监听,点击落在锚点视图之外时回调。
@MainActor
final class OutsideClickObserver {
    let box = OutsideClickAnchorBox()
    var onDismiss: (() -> Void)?
    private var monitor: Any?

    /// 安装监听(已安装时无操作)。
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    /// 移除监听。
    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// 命中检测:点击在宿主窗口内、且不在锚点视图范围内才收起;选择浮层与右键菜单展示时交给它们自己处理。
    /// - Parameter event: 鼠标事件
    private func handle(_ event: NSEvent) {
        if PickerPanelController.shared.isPresented || OMContextMenuCenter.shared.isPresented { return }
        guard let view = box.view, let window = view.window, event.window === window else { return }
        if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { return }
        onDismiss?()
    }
}

private struct OutsideClickCollapseModifier: ViewModifier {
    let isActive: Bool
    let onDismiss: () -> Void
    @State private var observer = OutsideClickObserver()

    func body(content: Content) -> some View {
        content
            .background(OutsideClickAnchor(box: observer.box))
            .onChange(of: isActive, initial: true) { _, active in
                observer.onDismiss = onDismiss
                if active { observer.install() } else { observer.remove() }
            }
            .onDisappear { observer.remove() }
    }
}

extension View {
    /// 弹层展开时,点击本视图范围之外就收起(点击照常穿透到被点的控件)。
    /// - Parameters:
    ///   - isActive: 弹层是否展开(未展开不安装监听)
    ///   - onDismiss: 收起回调
    func omCollapseOnOutsideClick(isActive: Bool, onDismiss: @escaping () -> Void) -> some View {
        modifier(OutsideClickCollapseModifier(isActive: isActive, onDismiss: onDismiss))
    }
}
