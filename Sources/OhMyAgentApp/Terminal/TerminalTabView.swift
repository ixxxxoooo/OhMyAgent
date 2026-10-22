// @author ixxxxoooo
// 终端视图:承载 TerminalStore 中的 SwiftTerm 视图;进程退出后显示提示条并可重新启动。

import DesignSystem
import IconKit
import SwiftTerm
import SwiftUI

/// 终端宿主容器:同一个终端视图只能挂在一处,而 Agent 窗口(含已隐藏的)与 IDE 窗口会各自挂载同一终端。
/// 容器只在自己的窗口可见时认领终端视图——隐藏窗口里的宿主重建(如主题切换重建窗口)不会再把视图抢走,
/// 窗口重新成为键盘窗口时再认领回来,所以「在哪个窗口操作就在哪个窗口显示」。
@MainActor
final class TerminalContainerView: NSView {
    let controller: TerminalController
    private var observers: [NSObjectProtocol] = []

    init(controller: TerminalController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.claim() }
            })
        }
        claim()
    }

    /// 本容器是否正持有终端视图。
    var ownsTerminal: Bool { controller.view.superview === self }

    /// 窗口可见时把终端视图挂到本容器(从原宿主摘下)。
    /// - Returns: 本次是否发生了接管
    @discardableResult
    func claim() -> Bool {
        guard let window, window.isVisible, !window.isMiniaturized, !ownsTerminal else { return false }
        let view = controller.view
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        controller.hostToken = self
        return true
    }

    /// 释放终端视图(宿主销毁时,仅当仍由本容器持有)。
    func release() {
        if ownsTerminal { controller.view.removeFromSuperview() }
        if controller.hostToken === self { controller.hostToken = nil }
    }
}

/// 把控制器持有的 AppKit 终端视图嵌入 SwiftUI。
private struct TerminalHostView: NSViewRepresentable {
    let controller: TerminalController
    /// 出现时是否抢占键盘焦点
    var focusOnAppear = true

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(controller: controller)
        if focusOnAppear {
            Task { @MainActor [weak container] in
                guard let container, container.claim() || container.ownsTerminal else { return }
                container.window?.makeFirstResponder(controller.view)
            }
        }
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        nsView.claim()
        if nsView.ownsTerminal { controller.view.syncTabActive(context.environment.tabIsActive) }
    }

    static func dismantleNSView(_ nsView: TerminalContainerView, coordinator: ()) {
        nsView.release()
    }
}

/// 终端标签/面板内容。
struct TerminalTabView: View {
    let id: String
    /// 控制器不存在时使用的启动目录
    let fallbackDirectory: String
    var focusOnAppear = true

    var body: some View {
        let controller = TerminalStore.shared.controller(for: id, fallbackDirectory: fallbackDirectory)
        VStack(spacing: 0) {
            TerminalHostView(controller: controller, focusOnAppear: focusOnAppear)
                // 实时缩放期间终端保持原尺寸,由这里裁剪到当前布局范围(见 LiveResizeGate)
                .clipped()
                .padding(.leading, 6)
                .background(Color(nsColor: OMTerminalPalette.background))
            if !controller.isRunning { exitedBar(controller) }
        }
        .accessibilityLabel("终端")
    }

    /// 进程结束提示条。
    private func exitedBar(_ controller: TerminalController) -> some View {
        HStack(spacing: 8) {
            Image.om("info", size: 12)
            Text(controller.exitCode.map { String(localized: "进程已退出(退出码 \(Int($0))))") } ?? String(localized: "进程已结束"))
                .font(OMFonts.small)
            Spacer()
            Button("重新启动") { controller.start() }
                .buttonStyle(.omSecondary)
        }
        .foregroundStyle(OMColors.secondaryText)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(OMColors.surface)
    }
}
