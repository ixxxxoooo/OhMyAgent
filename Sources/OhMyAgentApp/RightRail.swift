import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 右栏收起时,悬浮在工作区右上角的快捷竖条(对照 Cursor):展开右栏,或直接打开 Git 改动、浏览器、终端、文件标签。
/// - Author: ixxxxoooo
struct RightRail: View {
    @Bindable var workbench: WorkbenchModel
    private let actions = AppActions.shared

    var body: some View {
        VStack(spacing: 2) {
            RailButton(icon: "chevrons-left", label: WorkbenchPanelNames.toggleTitle(.tools, visible: false)) { workbench.toggleRight() }
            RailButton(icon: "diff", label: String(localized: "改动")) { actions.addRightTab("git") }
            RailButton(icon: "globe", label: String(localized: "浏览器")) { actions.addRightTab("browser") }
            RailButton(icon: "square-terminal", label: String(localized: "终端")) { actions.addRightTab("terminal") }
            RailButton(icon: "file", label: String(localized: "文件")) { actions.addRightTab("files") }
        }
        .padding(4)
        .omGlassCard(cornerRadius: OMRadius.floating)
        .padding(.top, TitlebarMetrics.height + OMSpacing.sm)
        .padding(.trailing, OMSpacing.sm)
    }
}

/// 竖条里的单个图标按钮。
private struct RailButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image.om(icon, size: 14)
                .frame(width: 28, height: 28)
                .background(hovering ? OMColors.pressedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(OMColors.secondaryText)
        .onHover { hovering = $0 }
        .omTooltip(label)
        .accessibilityLabel(label)
    }
}
