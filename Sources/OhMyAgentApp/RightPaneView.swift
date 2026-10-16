// @author ygw
// 右栏检查器:本轮改动(当前会话最近一次的文件改动汇总)与计划(Agent 最近一次的任务清单)。

import IconKit
import ChatKit
import DesignSystem
import SwiftUI
import WorkbenchKit

struct RightPaneView: View {
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        VStack(spacing: 0) {
            paneBar
            Divider()
            switch workbench.layout.rightPane {
            case .changes: ChangesPane(workbench: workbench)
            case .files: ExplorerView(workbench: workbench)
            case .search: SearchPaneView(workbench: workbench)
            case .git: SCMView(workbench: workbench)
            case .terminal: RightTerminalPane(workbench: workbench)
            default: sessionContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(OMColors.surface)
    }

    /// 图标分段条:右栏窄时也能放下 6 个视图;当前视图的标题显示在右侧。
    private var paneBar: some View {
        HStack(spacing: 2) {
            ForEach(RightPane.available, id: \.self) { pane in
                let selected = workbench.layout.rightPane == pane
                Button { workbench.layout.rightPane = pane } label: {
                    Image.om(Self.icon(pane), size: 14)
                        .frame(width: 28, height: 24)
                        .background(selected ? OMColors.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? OMColors.accent : OMColors.secondaryText)
                .help(Self.title(pane))
                .accessibilityLabel(Self.title(pane))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 4)
            Text(Self.title(workbench.layout.rightPane))
                .font(OMFonts.small.weight(.semibold))
                .foregroundStyle(OMColors.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    @ViewBuilder
    private var sessionContent: some View {
        VStack(spacing: 0) {
            if let model = workbench.activeSession {
                content(model: model)
            } else {
                ContentUnavailableView { Label("没有会话", om: "bubble.left", size: 28) } description: { Text("选择一个项目后,这里会显示改动与计划。") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(OMColors.surface)
    }

    @ViewBuilder
    private func content(model: SessionModel) -> some View {
        switch workbench.layout.rightPane {
        case .plan:
            if let entry = model.timeline.entries.last(where: { $0.kind == .plan }) {
                ScrollView {
                    PlanView(entry: entry).padding(10)
                }
            } else {
                ContentUnavailableView { Label("暂无计划", om: "checklist", size: 28) } description: { Text("Agent 制定任务计划后会显示在这里。") }
            }
        case .outline, .problems, .files, .search, .changes, .git, .terminal:
            EmptyView()
        }
    }

    /// 右栏视图对应的图标(Lucide 名)。
    static func icon(_ pane: RightPane) -> String {
        switch pane {
        case .changes: return "file-diff"
        case .plan: return "list-checks"
        case .outline: return "list"
        case .problems: return "triangle-alert"
        case .files: return "folder"
        case .search: return "search"
        case .git: return "git-branch"
        case .terminal: return "terminal"
        }
    }

    static func title(_ pane: RightPane) -> String {
        switch pane {
        case .changes: return String(localized: "改动")
        case .plan: return String(localized: "计划")
        case .outline: return String(localized: "大纲")
        case .problems: return String(localized: "问题")
        case .files: return String(localized: "文件")
        case .search: return String(localized: "搜索")
        case .git: return String(localized: "Git")
        case .terminal: return String(localized: "终端")
        }
    }
}

/// 右栏收起时贴在窗口右缘的快捷列表:一键展开右栏并切换到对应视图,或打开底部面板。
struct RightRail: View {
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(RightPane.available, id: \.self) { pane in
                railButton(title: RightPaneView.title(pane), icon: RightPaneView.icon(pane)) {
                    workbench.showRight(pane)
                }
            }
            railButton(title: String(localized: "输出"), icon: "panel-bottom") {
                workbench.showBottom(.output)
            }
            Spacer()
        }
        .padding(.top, 10)
        .frame(width: 34)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Divider() }
    }

    private func railButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image.om(icon, size: 15)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(OMColors.secondaryText)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// 「改动」页:本轮 Agent 的文件改动汇总(未提交的 Git 改动见「Git」页)。
struct ChangesPane: View {
    let workbench: WorkbenchModel

    var body: some View {
        if let model = workbench.activeSession,
           let entry = model.timeline.entries.last(where: { $0.kind == .changes && !$0.changes.isEmpty }) {
            ScrollView {
                ChangesSummaryView(entry: entry)
                    .environment(model)
                    .padding(10)
            }
        } else {
            ContentUnavailableView { Label("暂无改动", om: "doc.on.doc", size: 28) } description: { Text("Agent 修改文件后,这里会列出每个文件的差异;提交与分支请到 Git 页。") }
        }
    }
}

/// 右栏终端:项目级常驻 shell(与底部面板、终端标签相互独立),切换分段不会结束进程。
struct RightTerminalPane: View {
    let workbench: WorkbenchModel

    var body: some View {
        let root = workbench.selectedProjectID ?? NSHomeDirectory()
        TerminalTabView(id: "right:\(root)", fallbackDirectory: root, focusOnAppear: false)
            .id(root)
    }
}
