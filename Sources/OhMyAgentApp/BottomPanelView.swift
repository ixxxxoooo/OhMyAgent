// @author ixxxxoooo
// 底部面板:顶部可拖拽调整高度的分隔条 + 标签(输出,后续加入终端与问题)+ 内容。

import IconKit
import ChatKit
import DesignSystem
import SwiftUI
import WorkbenchKit

struct BottomPanelView: View {
    @Bindable var workbench: WorkbenchModel
    @State private var dragStartHeight: Double?

    /// 底部面板可用的视图:只列出摆放在底部的面板(终端、输出)。
    private var panes: [BottomPane] {
        BottomPane.available.filter { pane in
            switch pane {
            case .terminal: return workbench.layout.placement.terminal == .bottom
            case .output: return workbench.layout.placement.output == .bottom
            case .problems: return false
            }
        }
    }

    /// 实际显示的视图(当前选择不在底部时取第一个可用的)。
    private var currentPane: BottomPane {
        panes.contains(workbench.layout.bottomPane) ? workbench.layout.bottomPane : (panes.first ?? .output)
    }

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            HStack(spacing: 4) {
                ForEach(panes, id: \.self) { pane in
                    Button(Self.title(pane)) { workbench.layout.bottomPane = pane }
                        .buttonStyle(.plain)
                        .font(OMFonts.small.weight(currentPane == pane ? .semibold : .regular))
                        .foregroundStyle(currentPane == pane ? OMColors.primaryText : OMColors.secondaryText)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(currentPane == pane ? OMColors.selectedFill : .clear, in: OMPillShape())
                }
                Spacer()
                Button { workbench.layout.bottomVisible = false } label: { Image.om("xmark") }
                    .buttonStyle(.omPlain)
                    .help("关闭面板 (\(ShortcutStore.shared.binding(for: .togglePanel).display))")
                    .accessibilityLabel("关闭底部面板")
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background { Color.clear.terminalDragHandle(workbench, panel: currentPane == .terminal ? .terminal : .output) }
            Divider()
            Group {
                switch currentPane {
                case .output: LogViewerView()
                case .terminal:
                    // 底部面板使用项目级常驻终端;面板隐藏/切换标签都不会结束其中的进程
                    let root = workbench.selectedProjectID ?? NSHomeDirectory()
                    TerminalTabView(id: "bottom:\(root)", fallbackDirectory: root)
                case .problems: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: CGFloat(workbench.layout.bottomHeight))
        .background(OMColors.surface)
    }

    /// 顶部 1pt 分隔线 + 5pt 高的拖拽热区。
    private var resizeHandle: some View {
        Rectangle()
            .fill(OMColors.hairline)
            .frame(height: 1)
            .overlay {
                Color.clear.frame(height: 7).contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStartHeight ?? workbench.layout.bottomHeight
                            dragStartHeight = start
                            workbench.layout.bottomHeight = min(max(start - value.translation.height, 120), 600)
                        }
                        .onEnded { _ in dragStartHeight = nil })
            }
    }

    private static func title(_ pane: BottomPane) -> String {
        switch pane {
        case .terminal: return String(localized: "终端")
        case .output: return String(localized: "输出")
        case .problems: return String(localized: "问题")
        }
    }
}
