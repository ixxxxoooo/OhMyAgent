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

    /// 轻量轮询 Git 状态(应用在前台才刷新,状态不变时退避):保证资源管理器的 Git 装饰及时出现。
    private func pollGitBadge() async {
        guard let model = gitModel else { return }
        var delay = 6.0
        while !Task.isCancelled {
            // 应用在后台时跳过轮询;但首次(仓库还没发现)总要取一次,否则 Git 装饰迟迟不出现
            if NSApp.isActive || model.phase == .unknown {
                let before = model.status
                let started = ContinuousClock.now
                await model.refresh(full: false)
                let took = (ContinuousClock.now - started).seconds
                delay = PollBackoff.next(previous: delay, changed: model.status != before, duration: took, base: 6, maximum: 60)
            }
            try? await Task.sleep(for: .seconds(delay))
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
