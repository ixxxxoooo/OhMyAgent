// @author ixxxxoooo
// 面板摆放相关视图:项目栏/右栏停靠区的可拖动标题条(拖到工作区左/右半边即可换侧)与拖动时的落点高亮浮层。

import DesignSystem
import IconKit
import Observation
import SwiftUI
import WorkbenchKit

/// 可拖动换位置的面板(项目栏、工具栏、终端、输出共用同一套拖动与落点逻辑)。
typealias DraggablePanel = PanelItem

extension PanelItem {
    /// 面板标题。
    var title: String {
        switch self {
        case .sidebar: return String(localized: "项目栏")
        case .tools: return String(localized: "工具栏")
        }
    }

    /// 拖动提示。
    var dragHelp: String {
        switch self {
        case .sidebar, .tools: return String(localized: "拖动可把\(title)移到左侧或右侧")
        }
    }
}

/// 面板拖动状态(全应用共享;同一时刻只会有一次拖动)。
@MainActor
@Observable
final class TerminalDragState {
    static let shared = TerminalDragState()

    /// 是否正在拖动面板标题条
    private(set) var isDragging = false
    /// 正在拖动的面板
    private(set) var panel: DraggablePanel = .tools
    /// 当前指针(全局坐标)
    private(set) var pointer: CGPoint = .zero
    /// 工作区在全局坐标中的范围(由工作台视图上报)。
    /// 不参与观察:窗口缩放时每帧都会写它,而只有拖动中才会读取(`target` 同时依赖会触发刷新的 `pointer`)。
    @ObservationIgnored var workspaceFrame: CGRect = .zero

    /// 当前落点;指针在工作区之外为 nil。
    var target: PanelZone? {
        guard isDragging else { return nil }
        let local = CGPoint(x: pointer.x - workspaceFrame.minX, y: pointer.y - workspaceFrame.minY)
        return panel.dropTarget(at: local, in: workspaceFrame.size)
    }

    /// 拖动中更新指针位置。
    /// - Parameters:
    ///   - location: 全局坐标
    ///   - panel: 被拖动的面板
    func update(_ location: CGPoint, panel: DraggablePanel) {
        isDragging = true
        self.panel = panel
        pointer = location
    }

    /// 结束拖动。
    /// - Returns: 松手时的落点(越界取消为 nil)
    func finish(at location: CGPoint) -> PanelZone? {
        pointer = location
        let result = target
        isDragging = false
        return result
    }
}

/// 把视图变成「面板标题条」:在其空白处按下并拖动即可移动面板到别的位置。
private struct TerminalDragHandle: ViewModifier {
    let workbench: WorkbenchModel
    let panel: DraggablePanel

    func body(content: Content) -> some View {
        content.background(
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .global)
                        .onChanged { TerminalDragState.shared.update($0.location, panel: panel) }
                        .onEnded { value in
                            if let zone = TerminalDragState.shared.finish(at: value.location) {
                                omWithAnimation { workbench.place(panel, in: zone) }
                            }
                        }
                )
        )
        .omTooltip(panel.dragHelp)
    }
}

extension View {
    /// 使视图成为可拖动的面板标题条。
    /// - Parameters:
    ///   - workbench: 工作台模型(松手时据此换位置)
    ///   - panel: 被拖动的面板(项目栏或右栏停靠区)
    func terminalDragHandle(_ workbench: WorkbenchModel, panel: DraggablePanel) -> some View {
        modifier(TerminalDragHandle(workbench: workbench, panel: panel))
    }
}

/// 拖动面板时盖在工作区上的落点高亮(不拦截鼠标)。
struct TerminalDropOverlay: View {
    private let drag = TerminalDragState.shared

    var body: some View {
        GeometryReader { proxy in
            if drag.isDragging {
                ZStack(alignment: .topLeading) {
                    if let target = drag.target {
                        let rect = target.highlight(in: proxy.size)
                        RoundedRectangle(cornerRadius: OMRadius.control)
                            .fill(OMColors.selectedFill)
                            .overlay(RoundedRectangle(cornerRadius: OMRadius.control).strokeBorder(OMColors.accent.opacity(0.75), lineWidth: 2))
                            .overlay { Text(drag.panel.title + " → " + Self.title(target)).font(OMFonts.body.weight(.medium)).foregroundStyle(OMColors.accent) }
                            .frame(width: max(0, rect.width - 8), height: max(0, rect.height - 8))
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    private static func title(_ zone: PanelZone) -> String {
        zone == .left ? String(localized: "左侧") : String(localized: "右侧")
    }
}
