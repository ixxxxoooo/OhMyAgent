// @author ixxxxoooo
// 右栏:文件 / 搜索 / Git 三个视图(本轮 Agent 改动与提交图谱并入 Git 页;计划在输入区上方的待办条;终端在底部面板与终端标签)。

import AppKit
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
            case .git: SCMView(workbench: workbench)
            case .search: SearchPaneView(workbench: workbench)
            default: ExplorerView(workbench: workbench)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .padding(.leading, 8)
        // 右上角留给右栏开关浮层
        .padding(.trailing, TitlebarMetrics.trailingInset)
        .frame(height: TitlebarMetrics.height)
        .background(WindowDragArea())
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

/// 侧栏材质背景:左右栏共用的同一视觉效果。
struct SidebarBackground: View {
    var body: some View {
        // 选择主题包后侧栏使用主题派生的纯色;系统主题保持原生侧栏毛玻璃
        if let palette = ThemeRuntime.palette {
            palette.surface.mixed(with: palette.editorForeground, palette.isDark ? 0.045 : 0.035).color
        } else {
            SidebarMaterial()
        }
    }
}

/// 原生侧栏毛玻璃。
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
