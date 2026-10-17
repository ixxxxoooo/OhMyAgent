// @author ixxxxoooo
// 终端/输出面板摆放相关视图:左/右侧面板、可拖动的标题条(拖到工作区的左/右/下边缘或中心即可换位置)、
// 拖动时的落点高亮浮层。落点判定复用停靠区的五区命中测试(`DockDropZone`),见 `TerminalPlacement.dropTarget`。

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
        case .terminal: return String(localized: "终端")
        case .output: return String(localized: "输出")
        }
    }

    /// 拖动提示。
    var dragHelp: String {
        switch self {
        case .sidebar, .tools: return String(localized: "拖动可把\(title)移到左侧或右侧")
        case .terminal, .output: return String(localized: "拖动可把\(title)移到左侧、右侧、底部或编辑区")
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
    private(set) var panel: DraggablePanel = .terminal
    /// 当前指针(全局坐标)
    private(set) var pointer: CGPoint = .zero
    /// 工作区在全局坐标中的范围(由工作台视图上报)
    var workspaceFrame: CGRect = .zero

    /// 当前落点;指针在工作区之外为 nil。
    var target: TerminalPlacement? {
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
    func finish(at location: CGPoint) -> TerminalPlacement? {
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
                            if let placement = TerminalDragState.shared.finish(at: value.location),
                               let zone = PanelZone(rawValue: placement.rawValue) {
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
    ///   - panel: 被拖动的面板,默认终端
    func terminalDragHandle(_ workbench: WorkbenchModel, panel: DraggablePanel = .terminal) -> some View {
        modifier(TerminalDragHandle(workbench: workbench, panel: panel))
    }
}

/// 左/右侧终端面板:标题条(可拖动 + 关闭)+ 项目级常驻终端。
/// 终端标识沿用 `bottom:{项目根}`,换位置、隐藏都不会结束其中的进程。
struct TerminalSidePanel: View {
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        let insets = workbench.layout.titlebarInsets(for: .terminal)
        let root = workbench.selectedProjectID ?? NSHomeDirectory()
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image.om("square-terminal", size: 13)
                Text("终端").font(OMFonts.small.weight(.medium))
                Spacer(minLength: 4)
                Button { workbench.hideTerminal() } label: { Image.om("xmark") }
                    .buttonStyle(.omPlain)
                    .omTooltip(String(localized: "关闭终端 (\(ShortcutStore.shared.binding(for: .togglePanel).display))"))
                    .accessibilityLabel("关闭终端面板")
            }
            .foregroundStyle(OMColors.secondaryText)
            .padding(.leading, max(10, insets.leading)).padding(.trailing, max(10, insets.trailing))
            .frame(height: TitlebarMetrics.height)
            .terminalDragHandle(workbench)
            Divider()
            TerminalPanelView(workbench: workbench, root: root)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OMColors.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("终端面板")
    }
}

/// 输出侧栏:标题条(可拖动 + 关闭)+ 日志查看器。
struct OutputSidePanel: View {
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        let insets = workbench.layout.titlebarInsets(for: .output)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image.om("file-text", size: 13)
                Text("输出").font(OMFonts.small.weight(.medium))
                Spacer(minLength: 4)
                Button { workbench.hideOutput() } label: { Image.om("xmark") }
                    .buttonStyle(.omPlain)
                    .omTooltip("关闭输出")
                    .accessibilityLabel("关闭输出面板")
            }
            .foregroundStyle(OMColors.secondaryText)
            .padding(.leading, max(10, insets.leading)).padding(.trailing, max(10, insets.trailing))
            .frame(height: TitlebarMetrics.height)
            .terminalDragHandle(workbench, panel: .output)
            Divider()
            LogViewerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OMColors.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("输出面板")
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

    private static func title(_ placement: TerminalPlacement) -> String {
        switch placement {
        case .bottom: return String(localized: "底部")
        case .left: return String(localized: "左栏")
        case .right: return String(localized: "右栏")
        case .editor: return String(localized: "编辑区")
        }
    }
}
