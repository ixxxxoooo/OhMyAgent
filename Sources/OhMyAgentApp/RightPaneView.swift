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
        let _ = PanelToggleProbe.count("rightPane")
        VStack(spacing: 0) {
            paneBar
            if let chat = workbench.activeChat(in: .tools) {
                ChatPane(workbench: workbench, projectID: chat.projectID, slot: chat.slot)
            } else if workbench.layout.sidebarBrowserActive, let browserID = workbench.layout.sidebarBrowserID {
                BrowserTabView(browserID: browserID, workspace: workbench.selectedProjectID ?? NSHomeDirectory()).id(browserID)
            } else {
            switch workbench.layout.rightPane {
            case .git: SCMView(workbench: workbench)
            case .search: SearchPaneView(workbench: workbench)
            default: ExplorerView(workbench: workbench)
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: workbench.selectedProjectID) { await pollGitBadge() }
        // 与中间内容区背景一致(OMColors.surface),不与左侧栏一致
        .background(OMColors.surface)
    }

    /// 图标分段条:文件 / 搜索 / Git(对齐 VSCode 与 Cursor 的侧栏视图);当前视图标题显示在右侧。
    private var paneBar: some View {
        HStack(spacing: 2) {
            ForEach(workbench.layout.rightPaneOrder, id: \.self) { pane in
                let selected = workbench.layout.rightPane == pane && workbench.activeChat(in: .tools) == nil && !workbench.layout.sidebarBrowserActive
                Button { workbench.layout.rightPane = pane; workbench.layout.activeToolsChat = nil; workbench.layout.sidebarBrowserActive = false } label: {
                    Image.om(Self.icon(pane), size: 14)
                        .frame(width: 28, height: 24)
                        .background(selected ? OMColors.selectedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.tag))
                        .overlay(alignment: .topTrailing) { if pane == .git { gitDot } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 图标可拖进中间编辑区(边缘分屏、中心并入标签组)
                .onDrag {
                    DockDrag.shared.beginTools(pane)
                    return NSItemProvider(object: (DockDrag.toolsPrefix + pane.rawValue) as NSString)
                }
                // 图标之间也可互相拖放换顺序(同一份载荷同时服务编辑区落点)
                .dropDestination(for: String.self) { payloads, _ in
                    guard let text = payloads.first, text.hasPrefix(DockDrag.toolsPrefix),
                          let dragged = RightPane(rawValue: String(text.dropFirst(DockDrag.toolsPrefix.count))) else { return false }
                    omWithAnimation { workbench.moveRightPane(dragged, onto: pane) }
                    return true
                }
                .foregroundStyle(selected ? OMColors.accent : OMColors.secondaryText)
                .omTooltip(pane == .git ? (gitBadge?.tooltip.map { Self.title(pane) + ":" + $0 } ?? Self.title(pane)) : Self.title(pane))
                .accessibilityLabel(Self.title(pane))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if workbench.layout.sidebarBrowserID != nil { sidebarBrowserButton }
            ForEach(workbench.dockedChats(in: .tools)) { chat in
                DockedChatTab(workbench: workbench, chat: chat, iconOnly: true)
            }
            Spacer(minLength: 4)
            // 标题区同时是拖动手柄:按住拖到窗口左/右半边即可把工具栏换到那一侧
            Text(Self.title(workbench.layout.rightPane))
                .font(OMFonts.small.weight(.medium))
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
        .dropDestination(for: String.self) { payloads, _ in
            return dropChat(payloads, host: .tools, in: workbench)
        }
    }

    /// 右侧栏里的浏览器图标:点击切到浏览器;右键可移到编辑区或关闭。
    private var sidebarBrowserButton: some View {
        let selected = workbench.layout.sidebarBrowserActive && workbench.activeChat(in: .tools) == nil
        return Button {
            workbench.layout.sidebarBrowserActive = true
            workbench.layout.activeToolsChat = nil
        } label: {
            Image.om("globe", size: 14)
                .frame(width: 28, height: 24)
                .background(selected ? OMColors.selectedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.tag))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? OMColors.accent : OMColors.secondaryText)
        .omTooltip(String(localized: "浏览器"))
        .accessibilityLabel(String(localized: "浏览器"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .omContextMenu {
            OMMenuItem("移到编辑区", icon: "panel-top") { omWithAnimation { workbench.moveSidebarBrowserToEditor(title: String(localized: "浏览器")) } }
            OMMenuItem("关闭浏览器", icon: "x") { omWithAnimation { workbench.closeSidebarBrowserSlot() } }
        }
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
                .overlay(Circle().strokeBorder(OMColors.surface, lineWidth: 1))
                .offset(x: -2, y: 2)
                .accessibilityHidden(true)
        }
    }

    /// 右栏视图对应的图标(Lucide 名)。
    nonisolated static func icon(_ pane: RightPane) -> String {
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

    nonisolated static func title(_ pane: RightPane) -> String {
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

/// 侧栏背景:左侧栏与设置页左栏共用的同一纯色(浅色 #EFEFEF,见 OMColors.sidebar)。
struct SidebarBackground: View {
    var body: some View {
        OMColors.sidebar
    }
}
