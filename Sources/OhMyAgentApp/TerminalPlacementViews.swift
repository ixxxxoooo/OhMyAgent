// @author ixxxxoooo
// 终端摆放相关视图:左/右侧终端面板、可拖动的终端标题条(拖到工作区的左/右/下边缘或中心即可换位置)、
// 拖动时的落点高亮浮层。落点判定复用停靠区的五区命中测试(`DockDropZone`),见 `TerminalPlacement.dropTarget`。

import DesignSystem
import IconKit
import Observation
import SwiftUI
import WorkbenchKit

/// 终端拖动状态(全应用共享;同一时刻只会有一次拖动)。
@MainActor
@Observable
final class TerminalDragState {
    static let shared = TerminalDragState()

    /// 是否正在拖动终端标题条
    private(set) var isDragging = false
    /// 当前指针(全局坐标)
    private(set) var pointer: CGPoint = .zero
    /// 工作区在全局坐标中的范围(由工作台视图上报)
    var workspaceFrame: CGRect = .zero

    /// 当前落点;指针在工作区之外为 nil。
    var target: TerminalPlacement? {
        guard isDragging else { return nil }
        let local = CGPoint(x: pointer.x - workspaceFrame.minX, y: pointer.y - workspaceFrame.minY)
        return TerminalPlacement.dropTarget(at: local, in: workspaceFrame.size)
    }

    /// 拖动中更新指针位置。
    func update(_ location: CGPoint) {
        isDragging = true
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

/// 把视图变成「终端标题条」:在其空白处按下并拖动即可移动终端到别的位置。
private struct TerminalDragHandle: ViewModifier {
    let workbench: WorkbenchModel

    func body(content: Content) -> some View {
        content.background(
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .global)
                        .onChanged { TerminalDragState.shared.update($0.location) }
                        .onEnded { value in
                            if let placement = TerminalDragState.shared.finish(at: value.location) {
                                omWithAnimation { workbench.setTerminalPlacement(placement) }
                            }
                        }
                )
        )
        .help("拖动可把终端移到左侧、右侧、底部或编辑区")
    }
}

extension View {
    /// 使视图成为可拖动的终端标题条。
    /// - Parameter workbench: 工作台模型(松手时据此换位置)
    func terminalDragHandle(_ workbench: WorkbenchModel) -> some View {
        modifier(TerminalDragHandle(workbench: workbench))
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
                Text("终端").font(OMFonts.small.weight(.semibold))
                Spacer(minLength: 4)
                Button { workbench.hideTerminal() } label: { Image.om("xmark") }
                    .buttonStyle(.borderless)
                    .help("关闭终端 (\(ShortcutStore.shared.binding(for: .togglePanel).display))")
                    .accessibilityLabel("关闭终端面板")
            }
            .foregroundStyle(OMColors.secondaryText)
            .padding(.leading, max(10, insets.leading)).padding(.trailing, max(10, insets.trailing))
            .frame(height: TitlebarMetrics.height)
            .terminalDragHandle(workbench)
            Divider()
            TerminalTabView(id: "bottom:\(root)", fallbackDirectory: root)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OMColors.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("终端面板")
    }
}

/// 拖动终端时盖在工作区上的落点高亮(不拦截鼠标)。
struct TerminalDropOverlay: View {
    private let drag = TerminalDragState.shared

    var body: some View {
        GeometryReader { proxy in
            if drag.isDragging {
                ZStack(alignment: .topLeading) {
                    if let target = drag.target {
                        let rect = target.highlight(in: proxy.size)
                        RoundedRectangle(cornerRadius: 8)
                            .fill(OMColors.accent.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OMColors.accent.opacity(0.75), lineWidth: 2))
                            .overlay { Text(Self.title(target)).font(OMFonts.body.weight(.semibold)).foregroundStyle(OMColors.accent) }
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
