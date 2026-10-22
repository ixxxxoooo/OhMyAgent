// @author ixxxxoooo
// IDE 窗口标题栏(35pt,与 Agent 窗口一致):左侧红绿灯让位 + 侧栏开关;中间工作区名称(可拖动窗口);
// 右侧面板开关、Agent 面板开关、设置、最外侧「Agents Window ↗」。

import DesignSystem
import IconKit
import IDEKit
import SwiftUI

/// 标题栏图标按钮(与 Agent 窗口的浮层按钮同款:26pt、悬停底色、必带提示与无障碍标签)。
private struct TitleBarIconButton: View {
    let icon: String
    let label: String
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image.om(icon, size: 14)
                .frame(width: TitlebarMetrics.buttonSize, height: TitlebarMetrics.buttonSize)
                .background(hovering ? OMColors.pressedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? OMColors.primaryText : OMColors.secondaryText)
        .onHover { hovering = $0 }
        .omTooltip(label)
        .accessibilityLabel(label)
    }
}

/// IDE 标题栏。
struct IDETitleBar: View {
    let model: IDEWindowModel

    var body: some View {
        let shortcuts = ShortcutStore.shared
        HStack(spacing: TitlebarMetrics.buttonSpacing) {
            TitleBarIconButton(
                icon: model.sidebarVisible ? "panel-left-close" : "panel-left",
                label: (model.sidebarVisible ? String(localized: "隐藏侧栏") : String(localized: "显示侧栏")) + " (\(shortcuts.binding(for: .toggleSidebar).display))",
                isOn: model.sidebarVisible
            ) { model.toggleSidebar() }
                .padding(.leading, TitlebarMetrics.trafficLightInset)
            Spacer(minLength: 8)
            Text(model.workspaceName ?? String(localized: "未打开文件夹"))
                .font(OMFonts.small)
                .foregroundStyle(OMColors.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .allowsHitTesting(false)
            Spacer(minLength: 8)
            TitleBarIconButton(
                icon: model.panelVisible ? "panel-bottom-close" : "panel-bottom",
                label: (model.panelVisible ? String(localized: "隐藏面板") : String(localized: "显示面板")) + " (\(shortcuts.binding(for: .togglePanel).display))",
                isOn: model.panelVisible
            ) { model.togglePanel() }
            TitleBarIconButton(
                icon: model.agentPaneVisible ? "panel-right-close" : "panel-right",
                label: (model.agentPaneVisible ? String(localized: "隐藏 Agent 面板") : String(localized: "显示 Agent 面板")) + " (\(shortcuts.binding(for: .toggleInspector).display))",
                isOn: model.agentPaneVisible
            ) { model.toggleAgentPane() }
            TitleBarIconButton(icon: "settings", label: String(localized: "设置") + " (⌘,)") {
                AppActions.shared.openSettings()
            }
            ModeSwitchButton(target: .agent)
                .padding(.trailing, 8)
        }
        .frame(height: TitlebarMetrics.height)
        .frame(maxWidth: .infinity)
        // 拖动区必须在背景色之上(先加拖动区、再加背景色),否则不透明背景会拦住按下事件
        .background(WindowDragArea())
        .background(OMColors.contentBackground)
    }
}
