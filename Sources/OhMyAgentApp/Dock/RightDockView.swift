// @author ixxxxoooo
// 右栏停靠区:与中栏同一套标签组/分屏/拖拽体系(`DockView(host: .right)`),
// 终端、输出、文件预览、Plan、资源管理器、搜索、Git、浏览器都是其中的标签,可关闭、可拖动、可上下左右分屏。

import AppKit
import DesignSystem
import GitKit
import IconKit
import SwiftUI
import WorkbenchKit

/// 右栏停靠区根视图。
struct RightDockView: View {
    @Bindable var workbench: WorkbenchModel
    /// 当前项目的 Git 模型(只读状态,用于资源管理器装饰与 Git 标签圆点)
    private var gitModel: GitModel? { workbench.selectedProjectID.map { GitStore.shared.model(for: $0) } }

    var body: some View {
        let _ = PanelToggleProbe.count("rightDock")
        DockView(workbench: workbench, host: .right)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task(id: workbench.selectedProjectID) { await pollGitBadge() }
            // 与中间内容区背景一致(OMColors.surface),不与左侧栏一致
            .background(OMColors.surface)
    }

    /// 保持 Git 状态新鲜:先取一次,之后由文件系统事件驱动刷新(未被监听覆盖时才低频轮询),
    /// 保证资源管理器的 Git 装饰及时出现,且空闲时零开销。
    private func pollGitBadge() async {
        guard let model = gitModel, let project = workbench.selectedProjectID else { return }
        await model.refresh(full: false)
        await WorkspaceWatchCenter.shared.followProject(project, poll: .seconds(15)) {
            // 应用在后台时跳过(切回前台后的下一次事件或兜底刷新会补上);仓库尚未发现时总要取一次
            guard NSApp.isActive || model.phase == .unknown else { return }
            await model.refresh(full: false)
        }
    }
}

/// 右栏视图对应的图标(Lucide 名)。
func toolsPaneIcon(_ pane: RightPane) -> String {
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

/// 侧栏背景:左侧栏与设置页左栏共用的同一纯色(浅色 #EFEFEF,见 OMColors.sidebar)。
struct SidebarBackground: View {
    var body: some View {
        OMColors.sidebar
    }
}
