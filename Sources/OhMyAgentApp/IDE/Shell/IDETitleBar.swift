// @author ixxxxoooo
// IDE 窗口标题栏(35pt,与 Agent 窗口一致):左侧红绿灯让位 + 侧栏开关;
// 中间命令中心(对齐 VS Code:回退 / 前进 + 显示工作区名的搜索框,点击打开快速打开);
// 右侧面板开关、Agent 面板开关、设置、最外侧「Agents Window ↗」;空白处可拖动窗口。

import DesignSystem
import IconKit
import IDEKit
import SwiftUI

/// 标题栏图标按钮(与 Agent 窗口的浮层按钮同款:26pt、悬停底色、必带提示与无障碍标签)。
private struct TitleBarIconButton: View {
    let icon: String
    let label: String
    var isOn = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image.om(icon, size: 14)
                .frame(width: TitlebarMetrics.buttonSize, height: TitlebarMetrics.buttonSize)
                .background(hovering && enabled ? OMColors.pressedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(!enabled ? OMColors.tertiaryText.opacity(0.6) : isOn ? OMColors.primaryText : OMColors.secondaryText)
        .onHover { hovering = $0 }
        .omTooltip(label)
        .accessibilityLabel(label)
    }
}

/// 标题栏中间的搜索框:显示工作区名,点击打开快速打开(⌘P)。
private struct CommandCenterField: View {
    let title: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: OMSpacing.xs) {
                Image.om("search", size: 12)
                Text(title).lineLimit(1).truncationMode(.middle)
            }
            .font(OMFonts.small)
            .foregroundStyle(OMColors.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(hovering ? OMColors.hoverFill : OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).strokeBorder(OMColors.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .omTooltip(label)
        .accessibilityLabel(label)
    }
}

/// IDE 标题栏。
struct IDETitleBar: View {
    let workspace: IDEWorkspace
    private var model: IDEWindowModel { workspace.model }
    /// 中间命令中心两侧为左右按钮组预留的宽度(取较宽的右侧,保证命令中心在窗口内居中)
    private static let sideReserve: CGFloat = 224
    /// 命令中心最大宽度
    private static let centerMaxWidth: CGFloat = 560

    var body: some View {
        buttons
            .overlay { commandCenter }
            .frame(height: TitlebarMetrics.height)
            .frame(maxWidth: .infinity)
            // 拖动区必须在背景色之上(先加拖动区、再加背景色),否则不透明背景会拦住按下事件
            .background(WindowDragArea())
            .background(OMColors.contentBackground)
    }

    /// 命令中心:回退 / 前进 + 搜索框,整体在窗口内水平居中。
    private var commandCenter: some View {
        let shortcuts = ShortcutStore.shared
        return HStack(spacing: TitlebarMetrics.buttonSpacing) {
            TitleBarIconButton(
                icon: "arrow-left",
                label: String(localized: "回退") + " (\(shortcuts.binding(for: .goBack).display))",
                enabled: model.canGoBack
            ) { model.goBack() }
            TitleBarIconButton(
                icon: "arrow-right",
                label: String(localized: "前进") + " (\(shortcuts.binding(for: .goForward).display))",
                enabled: model.canGoForward
            ) { model.goForward() }
            CommandCenterField(
                title: model.workspaceName ?? String(localized: "未打开文件夹"),
                label: String(localized: "转到文件…") + " (\(shortcuts.binding(for: .quickOpen).display))"
            ) { workspace.openPalette("") }
                .padding(.leading, OMSpacing.xs)
        }
        .frame(maxWidth: Self.centerMaxWidth)
        .padding(.horizontal, Self.sideReserve)
    }

    /// 左右两侧的按钮组。
    private var buttons: some View {
        let shortcuts = ShortcutStore.shared
        return HStack(spacing: TitlebarMetrics.buttonSpacing) {
            TitleBarIconButton(
                icon: "panel-left",
                label: (model.sidebarVisible ? String(localized: "隐藏侧栏") : String(localized: "显示侧栏")) + " (\(shortcuts.binding(for: .toggleSidebar).display))",
                isOn: model.sidebarVisible
            ) { model.toggleSidebar() }
                .padding(.leading, TitlebarMetrics.trafficLightInset)
            Spacer(minLength: 8)
            // 有新版本/下载中/待重启时显示(与 Agent 窗口侧栏底部同一个按钮),无更新时不占位
            UpdateFooterButton()
                .padding(.trailing, 4)
            TitleBarIconButton(
                icon: "panel-bottom",
                label: (model.panelVisible ? String(localized: "隐藏面板") : String(localized: "显示面板")) + " (\(shortcuts.binding(for: .togglePanel).display))",
                isOn: model.panelVisible
            ) { model.togglePanel() }
            TitleBarIconButton(
                icon: "panel-right",
                label: (model.agentPaneVisible ? String(localized: "隐藏 Agent 面板") : String(localized: "显示 Agent 面板")) + " (\(shortcuts.binding(for: .toggleInspector).display))",
                isOn: model.agentPaneVisible
            ) { model.toggleAgentPane() }
            TitleBarIconButton(icon: "settings", label: String(localized: "设置") + " (⌘,)") {
                AppActions.shared.openSettings()
            }
            ModeSwitchButton(target: .agent)
                .padding(.trailing, 8)
        }
    }
}
