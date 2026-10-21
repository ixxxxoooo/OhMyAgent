// @author ixxxxoooo
// 活动栏(48pt):资源管理器 / 搜索 / 源代码管理三个入口,底部为设置。底色 `OMColors.sidebar`。
// 再次点击当前视图收起侧栏,点另一个则切换并展开。

import DesignSystem
import IconKit
import IDEKit
import SwiftUI

/// IDE 活动栏。
struct IDEActivityBar: View {
    let model: IDEWindowModel

    var body: some View {
        VStack(spacing: 4) {
            ForEach(IDESidebarView.allCases, id: \.self) { view in
                ActivityItem(
                    icon: view.icon,
                    label: view.title,
                    selected: model.sidebarVisible && model.sidebarView == view
                ) { model.selectSidebar(view) }
            }
            Spacer(minLength: 0)
            ActivityItem(icon: "settings", label: String(localized: "设置"), selected: false) {
                AppActions.shared.openSettings()
            }
        }
        .padding(.vertical, 8)
        .frame(width: IDEMetrics.activityBarWidth)
        .frame(maxHeight: .infinity)
        .background(OMColors.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(OMColors.hairline).frame(width: 1) }
    }
}

/// 活动栏单项:选中时左侧有强调条与选中底色。
private struct ActivityItem: View {
    let icon: String
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image.om(icon, size: 16)
                .frame(width: 36, height: 36)
                .background(selected ? OMColors.selectedFill : (hovering ? OMColors.hoverFill : .clear), in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? OMColors.primaryText : OMColors.secondaryText)
        .onHover { hovering = $0 }
        .omTooltip(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension IDESidebarView {
    /// 活动栏图标名(Lucide)。
    var icon: String {
        switch self {
        case .explorer: "folder"
        case .search: "search"
        case .scm: "git-branch"
        }
    }

    /// 本地化标题(提示、侧栏头部)。
    var title: String {
        switch self {
        case .explorer: String(localized: "资源管理器")
        case .search: String(localized: "搜索")
        case .scm: String(localized: "源代码管理")
        }
    }
}
