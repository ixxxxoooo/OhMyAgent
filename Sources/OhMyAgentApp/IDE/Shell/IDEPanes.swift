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
    let workspace: IDEWorkspace
    private var model: IDEWindowModel { workspace.model }

    var body: some View {
        VStack(spacing: 0) {
            if !(model.workspaceName != nil && model.sidebarView == .explorer) { PaneHeader(title: model.sidebarView.title) }
            Group {
                if model.workspaceName != nil, model.sidebarView == .explorer {
                    IDEExplorerPane(workspace: workspace)
                } else if model.workspaceName != nil, model.sidebarView == .scm {
                    IDESCMPane(workspace: workspace)
                } else if model.workspaceName != nil, model.sidebarView == .search {
                    IDESearchPane(workspace: workspace, model: workspace.search)
                } else if let name = model.workspaceName {
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
    private var problems: ProblemsStore { model.problems }

    var body: some View {
        HStack(spacing: 12) {
            Label(model.workspaceName ?? String(localized: "未打开文件夹"), om: "folder")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            Button { model.showPanel(.problems) } label: {
                HStack(spacing: 4) {
                    Image.om("circle-x", size: 12)
                    Text("\(problems.errorCount)")
                    Image.om("triangle-alert", size: 12)
                    Text("\(problems.warningCount)")
                }
            }
            .buttonStyle(.plain)
            .omTooltip(String(localized: "显示问题面板"))
            .accessibilityLabel(String(localized: "显示问题面板"))
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
