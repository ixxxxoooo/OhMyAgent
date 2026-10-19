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
    /// 各标签在全局坐标中的范围(用于判断松手时是否落在某个标签上以换顺序)
    @State private var tabFrames: [BottomPane: CGRect] = [:]

    /// 底部面板可用的视图:只列出摆放在底部的面板(终端、输出)。
    private var panes: [BottomPane] {
        workbench.layout.bottomPaneOrder.filter { pane in
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
                    Button(Self.title(pane)) { workbench.layout.bottomPane = pane; workbench.layout.activeBottomChat = nil }
                        .buttonStyle(.plain)
                        .font(OMFonts.small.weight(isPaneActive(pane) ? .medium : .regular))
                        .foregroundStyle(isPaneActive(pane) ? OMColors.primaryText : OMColors.secondaryText)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(isPaneActive(pane) ? OMColors.selectedFill : .clear, in: OMPillShape())
                        // 标签可拖动:在标签条内松手 = 换顺序;拖到工作区边缘/中心 = 换面板位置
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tabFrames[pane] = $0 }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                                .onChanged { TerminalDragState.shared.update($0.location, panel: Self.panelItem(pane)) }
                                .onEnded { finishTabDrag(pane, at: $0.location) }
                        )
                }
                ForEach(workbench.dockedChats(in: .bottom)) { chat in
                    DockedChatTab(workbench: workbench, chat: chat)
                }
                Spacer()
                Button { workbench.layout.bottomVisible = false } label: { Image.om("xmark") }
                    .buttonStyle(.omPlain)
                    .omTooltip(String(localized: "关闭面板 (\(ShortcutStore.shared.binding(for: .togglePanel).display))"))
                    .accessibilityLabel("关闭底部面板")
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .dropDestination(for: String.self) { payloads, _ in
                return dropChat(payloads, host: .bottom, in: workbench)
            }
            .background { Color.clear.terminalDragHandle(workbench, panel: currentPane == .terminal ? .terminal : .output) }
            Divider()
            Group {
                if let chat = workbench.activeChat(in: .bottom) {
                    ChatPane(workbench: workbench, projectID: chat.projectID, slot: chat.slot)
                } else {
                switch currentPane {
                case .output: LogViewerView()
                case .terminal:
                    // 底部面板使用项目级常驻终端(可有多个);面板隐藏/切换标签都不会结束其中的进程
                    TerminalPanelView(workbench: workbench, root: workbench.selectedProjectID ?? NSHomeDirectory())
                case .problems: EmptyView()
                }
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

    /// 内置面板标签是否高亮(选中了停靠会话时都不高亮)。
    private func isPaneActive(_ pane: BottomPane) -> Bool {
        workbench.activeChat(in: .bottom) == nil && currentPane == pane
    }

    /// 底部标签对应的可拖动面板。
    private static func panelItem(_ pane: BottomPane) -> PanelItem { pane == .terminal ? .terminal : .output }

    /// 结束标签拖动:落在其他底部标签上则换顺序,落在工作区其他位置则换面板摆放。
    /// - Parameters:
    ///   - pane: 被拖动的标签
    ///   - location: 松手位置(全局坐标)
    private func finishTabDrag(_ pane: BottomPane, at location: CGPoint) {
        let placement = TerminalDragState.shared.finish(at: location)
        if let onto = tabFrames.first(where: { $0.key != pane && $0.value.contains(location) })?.key {
            omWithAnimation { workbench.moveBottomPane(pane, onto: onto) }
        } else if let placement, placement != .bottom, let zone = PanelZone(rawValue: placement.rawValue) {
            omWithAnimation { workbench.place(Self.panelItem(pane), in: zone) }
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
