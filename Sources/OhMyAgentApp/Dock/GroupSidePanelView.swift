// @author ixxxxoooo
// 标签组内的侧边面板:显示在组内容区右侧(资源管理器 / 搜索 / Git),可收起、可拖动宽度、可拖出成标签。
// 在面板里打开的文件成为本组(右栏聚焦组)的标签。

import AppKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 组内侧边面板。
struct GroupSidePanelView: View {
    @Bindable var workbench: WorkbenchModel
    @Environment(\.dockHost) private var host
    let groupID: UUID
    let panel: GroupSidePanel
    /// 位于窗口右上角时,为面板开关浮层让出的宽度
    var trailingInset: CGFloat = 0
    /// 拖动宽度中的临时值(松手才写回布局)
    @State private var liveWidth: Double?
    @State private var dragBase: Double?

    private var width: Double { liveWidth ?? panel.width }

    var body: some View {
        HStack(spacing: 0) {
            resizer
            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                paneContent
            }
            .frame(width: width)
            .background(OMColors.surface)
        }
    }

    /// 左缘分隔条:1pt 线 + 8pt 命中区;拖动只改本地临时宽度。
    private var resizer: some View {
        Rectangle()
            .fill(OMColors.hairline)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragBase ?? panel.width
                                if dragBase == nil { dragBase = base; PanelDragState.shared.beginHold() }
                                liveWidth = min(max(base - Double(value.translation.width), GroupSidePanel.widthRange.lowerBound), GroupSidePanel.widthRange.upperBound)
                            }
                            .onEnded { _ in
                                if dragBase != nil { PanelDragState.shared.endHold() }
                                dragBase = nil
                                if let committed = liveWidth { workbench.mutateDock(host) { $0.setSidePanelWidth(committed, in: groupID) } }
                                liveWidth = nil
                            }
                    )
                    .accessibilityHidden(true)
            }
    }

    /// 标题条:视图切换图标(可拖出成标签)+ 收起按钮。
    private var header: some View {
        HStack(spacing: 2) {
            ForEach(RightPane.available, id: \.self) { pane in
                let selected = pane == panel.pane
                Button { workbench.mutateDock(host) { $0.showSidePanel(pane, in: groupID) } } label: {
                    Image.om(toolsPaneIcon(pane), size: 14)
                        .frame(width: 28, height: 24)
                        .background(selected ? OMColors.selectedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.tag))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? OMColors.accent : OMColors.secondaryText)
                // 图标可拖到任意标签组(并入标签)或边缘(新建分屏)
                .onDrag {
                    DockDrag.shared.beginTools(pane)
                    return NSItemProvider(object: (DockDrag.toolsPrefix + pane.rawValue) as NSString)
                }
                .omTooltip(WorkbenchModel.toolsPaneTitle(pane))
                .accessibilityLabel(WorkbenchModel.toolsPaneTitle(pane))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 4)
            Button { omWithAnimation { workbench.mutateDock(host) { $0.toggleSidePanelCollapsed(in: groupID) } } } label: {
                Image.om("panel-right", size: 13)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.omIcon)
            .omTooltip("收起侧边面板")
            .accessibilityLabel("收起侧边面板")
        }
        .padding(.leading, 8)
        .padding(.trailing, max(8, trailingInset))
        .frame(height: TitlebarMetrics.height)
        .background(WindowDragArea())
    }

    @ViewBuilder
    private var paneContent: some View {
        switch panel.pane {
        case .git: SCMView(workbench: workbench)
        case .search: SearchPaneView(workbench: workbench)
        default: ExplorerView(workbench: workbench)
        }
    }
}
