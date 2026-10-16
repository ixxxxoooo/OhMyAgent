// @author ixxxxoooo
// 终端视图:承载 TerminalStore 中的 SwiftTerm 视图;进程退出后显示提示条并可重新启动。

import DesignSystem
import IconKit
import SwiftTerm
import SwiftUI

/// 把控制器持有的 AppKit 终端视图嵌入 SwiftUI。
private struct TerminalHostView: NSViewRepresentable {
    let controller: TerminalController
    /// 出现时是否抢占键盘焦点
    var focusOnAppear = true

    /// 宿主令牌:同一个终端视图先后挂到新旧两个位置(换面板位置)时,
    /// 旧宿主销毁不能把已经挂到新位置的视图摘走。
    final class Coordinator {
        let controller: TerminalController
        init(controller: TerminalController) { self.controller = controller }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> TerminalView {
        let view = controller.view
        controller.hostToken = context.coordinator
        if focusOnAppear {
            Task { @MainActor in view.window?.makeFirstResponder(view) }
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        nsView.syncTabActive(context.environment.tabIsActive)
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        // 视图已被新的宿主接管时不再摘除
        guard coordinator.controller.hostToken === coordinator else { return }
        if nsView.superview != nil { nsView.removeFromSuperview() }
        coordinator.controller.hostToken = nil
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
                .controlSize(.small)
        }
        .foregroundStyle(OMColors.secondaryText)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(OMColors.surface)
    }
}
