import AppKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 右栏收起时,悬浮在工作区右上角的快捷竖条(对照 Cursor):展开右栏,或直接打开 Git 改动、浏览器、终端、文件标签。
/// - Author: ixxxxoooo
struct RightRail: View {
    @Bindable var workbench: WorkbenchModel
    private let actions = AppActions.shared
    /// 当前项目的 Git 模型(右栏收起时右栏不再刷新它,由竖条接力)
    private var gitModel: GitModel? { workbench.selectedProjectID.map { GitStore.shared.model(for: $0) } }

    var body: some View {
        VStack(spacing: 2) {
            RailButton(icon: "chevrons-left", label: WorkbenchPanelNames.toggleTitle(.tools, visible: false)) { workbench.toggleRight() }
            RailButton(icon: "git-branch", label: String(localized: "源代码管理"), badge: gitModel.map { !$0.status.isClean } ?? false) { actions.addRightTab("git") }
            RailButton(icon: "globe", label: String(localized: "浏览器")) { actions.addRightTab("browser") }
            RailButton(icon: "square-terminal", label: String(localized: "终端")) { actions.addRightTab("terminal") }
            RailButton(icon: "file", label: String(localized: "文件")) { actions.addRightTab("files") }
        }
        .padding(4)
        .omGlassCard(cornerRadius: OMRadius.floating)
        .padding(.top, TitlebarMetrics.height + OMSpacing.sm)
        .padding(.trailing, OMSpacing.sm)
        .task(id: workbench.selectedProjectID) { await followGit() }
    }

    /// 右栏收起期间保持 Git 状态新鲜,让「有改动」圆点及时出现;竖条消失(任务取消)即停止。
    private func followGit() async {
        guard let model = gitModel, let project = workbench.selectedProjectID else { return }
        await model.refresh(full: false)
        await WorkspaceWatchCenter.shared.followProject(project, poll: .seconds(15)) {
            guard NSApp.isActive || model.phase == .unknown else { return }
            await model.refresh(full: false)
        }
    }
}

/// 竖条里的单个图标按钮。
private struct RailButton: View {
    let icon: String
    let label: String
    /// 是否在右上角显示「有变动」圆点
    var badge = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image.om(icon, size: 14)
                .frame(width: 28, height: 28)
                .background(hovering ? OMColors.pressedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(OMColors.accent).frame(width: 7, height: 7).padding(4) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(OMColors.secondaryText)
        .onHover { hovering = $0 }
        .omTooltip(label)
        .accessibilityLabel(label)
    }
}
