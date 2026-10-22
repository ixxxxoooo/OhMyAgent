// @author ixxxxoooo
// IDE 底部面板:终端(多终端、右侧列表)、问题(按文件分组的诊断)、输出(日志)三个标签页;支持最大化与关闭。
// 终端复用 `TerminalTabView`/`TerminalStore`,输出复用 `LogViewerView`;问题来自 `ProblemsStore`。

import DesignSystem
import IconKit
import IDEKit
import SwiftUI

struct IDEBottomPanel: View {
    let workspace: IDEWorkspace
    private var model: IDEWindowModel { workspace.model }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(OMColors.hairline).frame(height: 1)
            Group {
                switch model.panelTab {
                case .terminal: IDETerminalsView(workspace: workspace)
                case .problems: IDEProblemsView(workspace: workspace)
                case .output: LogViewerView()
                }
            }
        }
        .background(OMColors.surface)
    }

    private var header: some View {
        HStack(spacing: 2) {
            ForEach(IDEPanelTab.allCases, id: \.self) { tab in tabButton(tab) }
            Spacer(minLength: 0)
            if model.panelTab == .terminal {
                iconButton("plus", String(localized: "新建终端")) { workspace.newTerminal() }
                iconButton("trash", String(localized: "结束当前终端")) {
                    if let id = workspace.activeTerminalID { workspace.closeTerminal(id) }
                }
            }
            iconButton(model.panelMaximized ? "minimize-2" : "maximize-2", model.panelMaximized ? String(localized: "还原面板大小") : String(localized: "最大化面板")) {
                model.panelMaximized.toggle()
            }
            iconButton("x", String(localized: "关闭面板")) { model.togglePanel() }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }

    private func tabButton(_ tab: IDEPanelTab) -> some View {
        let selected = model.panelTab == tab
        return Button { model.panelTab = tab } label: {
            HStack(spacing: 4) {
                Text(Self.title(tab)).font(OMFonts.small)
                if tab == .problems, model.problems.totalCount > 0 {
                    Text("\(model.problems.totalCount)").font(OMFonts.caption)
                        .padding(.horizontal, 5)
                        .background(OMColors.selectedFill, in: OMPillShape())
                }
            }
            .foregroundStyle(selected ? OMColors.primaryText : OMColors.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .overlay(alignment: .bottom) { if selected { Rectangle().fill(OMColors.accent).frame(height: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 标签页标题。
    static func title(_ tab: IDEPanelTab) -> String {
        switch tab {
        case .terminal: return String(localized: "终端")
        case .problems: return String(localized: "问题")
        case .output: return String(localized: "输出")
        }
    }

    private func iconButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 14) }
            .buttonStyle(.omIcon)
            .omTooltip(title)
            .accessibilityLabel(title)
    }
}

/// 终端标签页:当前终端 + 右侧终端列表(多于一个时显示)。
private struct IDETerminalsView: View {
    let workspace: IDEWorkspace
    private var model: IDEWindowModel { workspace.model }
    /// 本项目的共享终端(与 Agent 窗口同一份)
    private var terminalIDs: [String] { workspace.terminalIDs }
    /// 当前显示的终端:窗口记录的活动终端不在列表里(如被另一个窗口关掉)时取最后一个
    private var activeID: String? { workspace.activeTerminalID }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                ForEach(terminalIDs, id: \.self) { id in
                    let active = id == activeID
                    TerminalTabView(id: id, fallbackDirectory: workspace.root ?? NSHomeDirectory(), focusOnAppear: active)
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(active)
                        .accessibilityHidden(!active)
                }
                if terminalIDs.isEmpty {
                    OMEmptyState { Label("还没有终端", om: "square-terminal") } description: { Text("新建一个终端来运行命令") } actions: {
                        Button("新建终端") { workspace.newTerminal() }
                    }
                }
            }
            if terminalIDs.count > 1 {
                Rectangle().fill(OMColors.hairline).frame(width: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(terminalIDs.enumerated()), id: \.element) { index, id in
                            row(id: id, index: index)
                        }
                    }
                }
                .frame(width: 140)
            }
        }
        .task { if terminalIDs.isEmpty { workspace.newTerminal() } }
    }

    private func row(id: String, index: Int) -> some View {
        let active = id == activeID
        return HStack(spacing: 6) {
            Image.om("square-terminal", size: 12)
            Text(String(localized: "终端") + " \(index + 1)").font(OMFonts.small).lineLimit(1)
            Spacer(minLength: 0)
            Button { workspace.closeTerminal(id) } label: { Image.om("x", size: 12) }
                .buttonStyle(.omIcon)
                .accessibilityLabel(String(localized: "结束当前终端"))
        }
        .foregroundStyle(active ? OMColors.primaryText : OMColors.secondaryText)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(active ? OMColors.selectedFill : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.activeTerminalID = id }
        .accessibilityAddTraits(.isButton)
    }
}

/// 问题标签页。
private struct IDEProblemsView: View {
    let workspace: IDEWorkspace
    private var store: ProblemsStore { workspace.model.problems }

    var body: some View {
        if store.totalCount == 0 {
            OMEmptyState { Label("没有发现问题", om: "circle-check", size: 28) } description: { Text("已打开文件的编译错误与警告会显示在这里。") }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.groups, id: \.path) { group in
                        HStack(spacing: 6) {
                            OMFileIcon(name: (group.path as NSString).lastPathComponent, size: 14)
                            Text((group.path as NSString).lastPathComponent).font(OMFonts.small)
                            Text(relative(group.path)).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1).truncationMode(.head)
                            Text("\(group.problems.count)").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).frame(height: 24)
                        ForEach(group.problems) { problem in ProblemRow(workspace: workspace, problem: problem) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func relative(_ path: String) -> String {
        guard let root = workspace.root, path.hasPrefix(root + "/") else { return (path as NSString).deletingLastPathComponent }
        return (String(path.dropFirst(root.count + 1)) as NSString).deletingLastPathComponent
    }
}

private struct ProblemRow: View {
    let workspace: IDEWorkspace
    let problem: IDEProblem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image.om(icon, size: 12).foregroundStyle(tint)
            Text(problem.message).font(OMFonts.small).foregroundStyle(OMColors.primaryText).lineLimit(2)
            Text("[\(problem.line), \(problem.column)]").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            Spacer(minLength: 0)
        }
        .padding(.leading, 32).padding(.trailing, 12)
        .frame(minHeight: 22)
        .background(hovering ? OMColors.hoverFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { workspace.model.openFile(problem.path, line: problem.line, preview: false) }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch problem.severity {
        case .error: return "circle-x"
        case .warning: return "triangle-alert"
        case .information, .hint: return "info"
        }
    }

    private var tint: Color {
        switch problem.severity {
        case .error: return OMColors.danger
        case .warning: return OMColors.warning
        case .information, .hint: return OMColors.secondaryText
        }
    }
}
