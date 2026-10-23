// @author ixxxxoooo
// 侧栏顶部的模式切换:两个纯图标按钮并排,「会话模式」(不绑定项目的通用会话)与「代码模式」(工作区:项目及其会话)。
// 位置在 35pt 顶部区域、红绿灯与左上浮层按钮的右侧;侧栏过窄放不下时自动退到顶部区域下方单独一行。

import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

extension TitlebarMetrics {
    /// 模式切换控件的宽度:两个 `buttonSize` 按钮 + 间距。
    static let sidebarSwitchWidth: CGFloat = buttonSize * 2 + buttonSpacing
    /// 控件与侧栏边缘的距离。
    static let sidebarSwitchInset: CGFloat = 8

    /// 模式切换控件能否放进侧栏顶部区域(与左上浮层同一行而不重叠)。
    /// - Parameters:
    ///   - sidebarWidth: 侧栏宽度
    ///   - toggles: 左侧面板开关个数(决定左上浮层宽度)
    ///   - overlayOnSidebarSide: 左上浮层是否压在侧栏上(侧栏在右侧时不压)
    /// - Returns: 放得下为 true
    static func sidebarSwitchFitsInStrip(sidebarWidth: Double, toggles: Int, overlayOnSidebarSide: Bool = true) -> Bool {
        guard overlayOnSidebarSide else { return true }
        let needed = leftClusterWidth(toggles: max(toggles, 1)) + sidebarSwitchWidth + sidebarSwitchInset
        return sidebarWidth >= Double(needed)
    }
}

/// 侧栏模式切换(会话模式 / 代码模式)。
struct SidebarModeSwitch: View {
    let workbench: WorkbenchModel

    var body: some View {
        HStack(spacing: TitlebarMetrics.buttonSpacing) {
            modeButton(.sessions, icon: "messages-square", label: String(localized: "会话模式"))
            modeButton(.workspaces, icon: "code", label: String(localized: "代码模式"))
        }
    }

    /// 单个模式按钮:选中态用选中底色与主文字色。
    private func modeButton(_ pane: LeftPane, icon: String, label: String) -> some View {
        let selected = workbench.layout.leftPane == pane
        return Button { workbench.switchLeftPane(pane) } label: {
            Image.om(icon, size: 14)
                .frame(width: TitlebarMetrics.buttonSize, height: TitlebarMetrics.buttonSize)
                .background(selected ? OMColors.selectedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? OMColors.primaryText : OMColors.secondaryText)
        .omTooltip(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 侧栏顶部区域:35pt 可拖动窗口的空白条,右侧放模式切换;放不下时切换控件另起一行。
struct SidebarTopStrip: View {
    let workbench: WorkbenchModel

    var body: some View {
        let layout = workbench.layout
        let fits = TitlebarMetrics.sidebarSwitchFitsInStrip(
            sidebarWidth: layout.leftWidth,
            toggles: layout.toggleCount(on: layout.side(of: .sidebar)),
            overlayOnSidebarSide: layout.side(of: .sidebar) == .left
        )
        VStack(spacing: 0) {
            Color.clear.frame(height: TitlebarMetrics.height).background(WindowDragArea())
                .overlay(alignment: .trailing) {
                    if fits { SidebarModeSwitch(workbench: workbench).padding(.trailing, TitlebarMetrics.sidebarSwitchInset) }
                }
            if !fits {
                HStack { SidebarModeSwitch(workbench: workbench); Spacer(minLength: 0) }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
    }
}
