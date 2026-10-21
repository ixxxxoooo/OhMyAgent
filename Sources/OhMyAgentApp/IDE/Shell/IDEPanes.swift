// @author ixxxxoooo
// IDE 外壳的各区域容器:侧栏、编辑区(空状态)、底部面板、Agent 面板、状态栏。
// 本阶段(I2)只提供布局与空状态,真实内容由后续里程碑接入(I3 侧栏三视图、I4 编辑器组、I9 底部面板、I11 Agent 面板)。

import DesignSystem
import IconKit
import IDEKit
import SwiftUI

/// 区域头部:标题 + 可选的右侧关闭按钮(24pt 紧凑)。
private struct PaneHeader: View {
    let title: String
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(OMFonts.small)
                .foregroundStyle(OMColors.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) { Image.om("x", size: 12) }
                    .buttonStyle(.omIcon)
                    .omTooltip(String(localized: "关闭"))
                    .accessibilityLabel(String(localized: "关闭"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }
}

/// 侧栏:头部显示当前视图名;内容区本阶段为空状态(无文件夹时给出「打开文件夹」)。
struct IDESidebarPane: View {
    let model: IDEWindowModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: model.sidebarView.title)
            Group {
                if let name = model.workspaceName {
                    OMEmptyState {
                        Label(name, om: model.sidebarView.icon)
                    } description: {
                        Text("该视图将在后续版本提供")
                    }
                } else {
                    OMEmptyState {
                        Label("尚未打开文件夹", om: "folder")
                    } description: {
                        Text("打开一个文件夹开始浏览与编辑")
                    } actions: {
                        Button("打开文件夹…") { IDEWindowManager.shared.chooseFolder(for: model) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(OMColors.sidebar)
    }
}

/// 编辑区:本阶段显示空状态与可用快捷键提示。
struct IDEEditorArea: View {
    let model: IDEWindowModel

    var body: some View {
        let shortcuts = ShortcutStore.shared
        VStack(spacing: 14) {
            Image.om("code", size: 28).foregroundStyle(OMColors.tertiaryText)
            VStack(spacing: 6) {
                hint(String(localized: "显示 / 隐藏侧栏"), shortcuts.binding(for: .toggleSidebar).display)
                hint(String(localized: "显示 / 隐藏面板"), shortcuts.binding(for: .togglePanel).display)
                hint(String(localized: "显示 / 隐藏 Agent 面板"), shortcuts.binding(for: .toggleInspector).display)
                hint(String(localized: "切换到 Agents Window"), shortcuts.binding(for: .switchWindowMode).display)
                hint(String(localized: "新建 IDE 窗口"), shortcuts.binding(for: .newIDEWindow).display)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OMColors.contentBackground)
    }

    private func hint(_ title: String, _ keys: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                .frame(width: 160, alignment: .trailing)
            Text(keys).font(OMFonts.small).foregroundStyle(OMColors.tertiaryText)
                .frame(width: 80, alignment: .leading)
        }
    }
}

/// 底部面板:本阶段为占位容器,带最大化与关闭。
struct IDEBottomPanel: View {
    let model: IDEWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("面板").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                Spacer(minLength: 0)
                Button { model.panelMaximized.toggle() } label: { Image.om(model.panelMaximized ? "minimize-2" : "maximize-2", size: 12) }
                    .buttonStyle(.omIcon)
                    .omTooltip(model.panelMaximized ? String(localized: "还原面板大小") : String(localized: "最大化面板"))
                    .accessibilityLabel(model.panelMaximized ? String(localized: "还原面板大小") : String(localized: "最大化面板"))
                Button { model.togglePanel() } label: { Image.om("x", size: 12) }
                    .buttonStyle(.omIcon)
                    .omTooltip(String(localized: "关闭面板"))
                    .accessibilityLabel(String(localized: "关闭面板"))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            Rectangle().fill(OMColors.hairline).frame(height: 1)
            OMEmptyState {
                Label("终端、问题与输出", om: "square-terminal")
            } description: {
                Text("面板内容将在后续版本提供")
            }
        }
        .background(OMColors.surface)
    }
}

/// Agent 面板:本阶段为占位容器。
struct IDEAgentPane: View {
    let model: IDEWindowModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: String(localized: "Agent")) { model.toggleAgentPane() }
            Rectangle().fill(OMColors.hairline).frame(height: 1)
            OMEmptyState {
                Label("Agent 面板", om: "sparkles")
            } description: {
                Text("在这里与 Agent 对话的功能将在后续版本提供")
            } actions: {
                Button("到 Agents Window 对话") { IDEWindowManager.shared.switchToAgent() }
            }
        }
        .frame(maxHeight: .infinity)
        .background(OMColors.surface)
    }
}

/// 状态栏(22pt):左侧工作区名称,右侧预留给行列、编码、语言等状态(后续里程碑)。
struct IDEStatusBar: View {
    let model: IDEWindowModel

    var body: some View {
        HStack(spacing: 12) {
            Label(model.workspaceName ?? String(localized: "未打开文件夹"), om: "folder")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(OMFonts.caption)
        .foregroundStyle(OMColors.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: IDEMetrics.statusBarHeight)
        .frame(maxWidth: .infinity)
        .background(OMColors.sidebar)
    }
}
