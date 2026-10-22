// @author ixxxxoooo
// IDE 外壳的各区域容器:侧栏、编辑区(空状态)、底部面板、Agent 面板、状态栏。
// 本阶段(I2)只提供布局与空状态,真实内容由后续里程碑接入(I3 侧栏三视图、I4 编辑器组、I9 底部面板、I11 Agent 面板)。

import DesignSystem
import EditorKit
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

/// 状态栏(22pt):左侧工作区名称与问题计数,右侧活动文件的行列、语言、编码。
struct IDEStatusBar: View {
    let workspace: IDEWorkspace
    private var model: IDEWindowModel { workspace.model }
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
            // 有新版本/下载中/待重启时显示(与 Agent 窗口侧栏底部同一个按钮),无更新时不占位
            UpdateFooterButton(compact: true)
            if let path = model.activeFilePath {
                // 语言服务器状态(原先显示在编辑区底部)
                if let controller = workspace.lspControllers[path] { LSPStatusItem(controller: controller) }
                if let caret = workspace.carets[path] {
                    Button { workspace.openPalette(":") } label: {
                        Text(caret.selectedLength > 0
                             ? String(localized: "行 \(caret.line),列 \(caret.column)(已选 \(caret.selectedLength))")
                             : String(localized: "行 \(caret.line),列 \(caret.column)"))
                    }
                    .buttonStyle(.plain)
                    .omTooltip(String(localized: "转到行…"))
                    .accessibilityLabel(String(localized: "转到行…"))
                }
                Text(Self.languageName(for: path))
                Text(verbatim: "UTF-8")
            }
        }
        .font(OMFonts.caption)
        .foregroundStyle(OMColors.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: IDEMetrics.statusBarHeight)
        .frame(maxWidth: .infinity)
        .background(OMColors.sidebar)
    }
}

extension IDEStatusBar {
    /// 语言的展示名(未识别为纯文本)。
    static func languageName(for path: String) -> String {
        let language = SyntaxLanguage.detect(path: path)
        switch language {
        case .plain: return String(localized: "纯文本")
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .sql: return "SQL"
        case .php: return "PHP"
        case .c: return "C/C++"
        default: return language.rawValue.prefix(1).uppercased() + language.rawValue.dropFirst()
        }
    }
}
