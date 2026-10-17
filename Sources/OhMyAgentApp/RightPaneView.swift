// @author ixxxxoooo
// 右栏:文件 / 搜索 / Git 三个视图(本轮 Agent 改动与提交图谱并入 Git 页;计划在输入区上方的待办条;终端在底部面板与终端标签)。

import AppKit
import IconKit
import ChatKit
import DesignSystem
import GitKit
import SwiftUI
import WorkbenchKit

struct RightPaneView: View {
    @Bindable var workbench: WorkbenchModel
    /// 当前项目的 Git 模型(只读状态,用于图标圆点)
    private var gitModel: GitModel? { workbench.selectedProjectID.map { GitStore.shared.model(for: $0) } }

    var body: some View {
        VStack(spacing: 0) {
            paneBar
            switch workbench.layout.rightPane {
            case .git: SCMView(workbench: workbench)
            case .search: SearchPaneView(workbench: workbench)
            default: ExplorerView(workbench: workbench)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: workbench.selectedProjectID) { await pollGitBadge() }
        // 与左侧栏同一材质(侧栏材质),不再使用正文白底
        .background(SidebarBackground())
    }

    /// 图标分段条:文件 / 搜索 / Git(对齐 VSCode 与 Cursor 的侧栏视图);当前视图标题显示在右侧。
    private var paneBar: some View {
        HStack(spacing: 2) {
            ForEach(RightPane.available, id: \.self) { pane in
                let selected = workbench.layout.rightPane == pane
                Button { workbench.layout.rightPane = pane } label: {
                    Image.om(Self.icon(pane), size: 14)
                        .frame(width: 28, height: 24)
                        .background(selected ? OMColors.selectedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.tag))
                        .overlay(alignment: .topTrailing) { if pane == .git { gitDot } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? OMColors.accent : OMColors.secondaryText)
                .help(pane == .git ? (gitBadge?.tooltip.map { Self.title(pane) + ":" + $0 } ?? Self.title(pane)) : Self.title(pane))
                .accessibilityLabel(Self.title(pane))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 4)
            // 标题区同时是拖动手柄:按住拖到窗口左/右半边即可把工具栏换到那一侧
            Text(Self.title(workbench.layout.rightPane))
                .font(OMFonts.small.weight(.semibold))
                .foregroundStyle(OMColors.secondaryText)
                .lineLimit(1)
                .frame(minWidth: 60, maxHeight: .infinity, alignment: .trailing)
                .terminalDragHandle(workbench, panel: .tools)
        }
        // 位于最外侧时,顶部角落留给面板开关浮层
        .padding(.leading, max(8, workbench.layout.titlebarInsets(for: .tools).leading))
        .padding(.trailing, workbench.layout.titlebarInsets(for: .tools).trailing)
        .frame(height: TitlebarMetrics.height)
        .background(WindowDragArea())
    }

    /// 非 Git 视图时的轻量轮询(应用在前台才刷新,状态不变时退避):保证圆点及时出现。
    private func pollGitBadge() async {
        guard let model = gitModel else { return }
        var delay = 6.0
        while !Task.isCancelled {
            // 应用在后台时跳过轮询;但首次(仓库还没发现)总要取一次,否则资源管理器的 Git 装饰迟迟不出现
            if workbench.layout.rightPane != .git, NSApp.isActive || model.phase == .unknown {
                let before = model.status
                let started = ContinuousClock.now
                await model.refresh(full: false)
                let took = (ContinuousClock.now - started).seconds
                delay = PollBackoff.next(previous: delay, changed: model.status != before, duration: took, base: 6, maximum: 60)
            }
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private var gitBadge: GitBadge? {
        guard let model = gitModel, model.phase == .ready else { return nil }
        let badge = GitBadge(status: model.status)
        return badge.isVisible ? badge : nil
    }

    /// Git 图标右上角的状态圆点:有未提交/未推送为强调色,仅待拉取为次要色。
    @ViewBuilder
    private var gitDot: some View {
        if let badge = gitBadge {
            Circle()
                .fill(badge.isOnlyBehind ? OMColors.accent2 : OMColors.accent)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(OMColors.sidebar, lineWidth: 1))
                .offset(x: -2, y: 2)
                .accessibilityHidden(true)
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

/// 侧栏背景:左右栏与设置页左栏共用的同一纯色(浅色 #EFEFEF,见 OMColors.sidebar)。
struct SidebarBackground: View {
    var body: some View {
        OMColors.sidebar
    }
}
