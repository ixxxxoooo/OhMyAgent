// @author ixxxxoooo
// 无标题栏窗口的顶部部件(对齐 kuku 的 TopLeftOverlay / TopRightOverlay):
// 窗口只保留红绿灯,侧栏开关与右栏开关以浮层固定在 35pt 顶部区域,坐标不随面板展开/收起而跳动;
// 顶部空白区(标签栏空白、侧栏顶部、右栏头部)可拖动窗口。

import AppKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 顶部区域尺寸常量。
enum TitlebarMetrics {
    /// 顶部区域高度(标签栏、侧栏顶部、右栏头部统一)。
    static let height: CGFloat = 35
    /// 让开红绿灯的安全边距。
    static let trafficLightInset: CGFloat = 88
    /// 浮层图标按钮的边长与按钮间距。
    static let buttonSize: CGFloat = 26
    static let buttonSpacing: CGFloat = 2
    /// 左上浮层(红绿灯让位 + 回退/前进 + `toggles` 个面板开关)的总宽度:`toggles == 1` 时为 170(对齐 kuku)。
    /// 修改浮层按钮构成时必须同步此函数。
    static func leftClusterWidth(toggles: Int) -> CGFloat {
        trafficLightInset + buttonSize * CGFloat(2 + toggles) + buttonSpacing * CGFloat(1 + toggles)
    }

    /// 右上浮层(`toggles` 个面板开关 + 边距)占用的宽度:`toggles == 1` 时为 34;没有开关时为 0。
    static func rightClusterWidth(toggles: Int) -> CGFloat {
        toggles <= 0 ? 0 : buttonSize * CGFloat(toggles) + buttonSpacing * CGFloat(toggles - 1) + 8
    }
}

/// 浮层按钮:图标 + 悬停底色;不可用时弱化且不响应。
private struct OverlayButton: View {
    let icon: String
    let label: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image.om(icon, size: 14)
                .frame(width: TitlebarMetrics.buttonSize, height: TitlebarMetrics.buttonSize)
                .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? OMColors.secondaryText : OMColors.tertiaryText.opacity(0.6))
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 顶部浮层:左上「回退 / 前进」+ 位于左侧的面板开关,右上位于右侧的面板开关。
/// 刻意做成整个工作区上的浮层(而不是塞进侧栏或标签栏):面板展开/收起时按钮坐标恒定,
/// 且窗口使用隐藏标题栏(不再有 NSTitlebarView 横跨顶部吞掉点击),按钮可直接点击。
/// 项目栏、工具栏的开关跟随各自所在的一侧(设置 → 主题 → 布局)。
struct TitlebarOverlay: View {
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: TitlebarMetrics.buttonSpacing) {
                OverlayButton(icon: "arrow-left", label: String(localized: "回退"), enabled: workbench.nav.canGoBack) { workbench.goBack() }
                OverlayButton(icon: "arrow-right", label: String(localized: "前进"), enabled: workbench.nav.canGoForward) { workbench.goForward() }
                ForEach(toggles(on: .left)) { toggleButton($0, side: .left) }
            }
            .padding(.leading, TitlebarMetrics.trafficLightInset)
            Spacer(minLength: 0)
            HStack(spacing: TitlebarMetrics.buttonSpacing) {
                // 右侧由内向外:工具栏在项目栏内侧
                ForEach(toggles(on: .right).reversed()) { toggleButton($0, side: .right) }
            }
            .padding(.trailing, 4)
        }
        .frame(height: TitlebarMetrics.height)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// 某一侧的面板开关(项目栏、工具栏),由外向内。
    private func toggles(on side: PanelSide) -> [PanelColumn] {
        workbench.layout.columns(on: side).filter { $0 != .terminal }
    }

    /// 单个面板开关按钮:图标随所在侧变化,提示与快捷键随面板变化。
    private func toggleButton(_ column: PanelColumn, side: PanelSide) -> some View {
        let isSidebar = column == .sidebar
        let visible = workbench.layout.isVisible(column)
        let shortcut = ShortcutStore.shared.binding(for: isSidebar ? .toggleSidebar : .toggleInspector).display
        let name = WorkbenchPanelNames.toggleTitle(column, visible: visible)
        return OverlayButton(
            icon: side == .left ? "panel-left" : "panel-right",
            label: name + " (\(shortcut))"
        ) {
            if isSidebar { workbench.toggleLeft() } else { workbench.toggleRight() }
        }
    }
}

/// 面板开关的本地化文案(标题栏按钮、菜单、命令面板共用)。
enum WorkbenchPanelNames {
    /// 面板开关的标题。
    /// - Parameters:
    ///   - column: 项目栏或工具栏
    ///   - visible: 当前是否可见(可见时文案为「隐藏」)
    /// - Returns: 本地化标题
    static func toggleTitle(_ column: PanelColumn, visible: Bool) -> String {
        switch (column, visible) {
        case (.sidebar, true): return String(localized: "隐藏项目栏")
        case (.sidebar, false): return String(localized: "显示项目栏")
        case (_, true): return String(localized: "隐藏工具栏")
        case (_, false): return String(localized: "显示工具栏")
        }
    }
}

extension WorkbenchLayout {
    /// 面板列顶部为标题栏浮层让出的(前,后)边距:仅当它是某一侧最外侧的可见列时才需要
    /// (项目栏顶部本来就是空白,无需让位)。
    /// - Parameter column: 面板列
    /// - Returns: 前缘与后缘的让位宽度
    func titlebarInsets(for column: PanelColumn) -> (leading: CGFloat, trailing: CGFloat) {
        guard column != .sidebar, let side = side(of: column), visibleColumns(on: side).first == column else { return (0, 0) }
        return side == .left
            ? (TitlebarMetrics.leftClusterWidth(toggles: toggleCount(on: .left)), 0)
            : (0, TitlebarMetrics.rightClusterWidth(toggles: toggleCount(on: .right)))
    }
}

/// 可拖动窗口的空白区域(放在背景层;命中时按下即拖动窗口,双击缩放)。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else if let window {
                window.performDrag(with: event)
            }
        }
    }
}

/// 窗口外观:透明标题栏 + 内容铺满整个窗口,只保留红绿灯。
enum WindowChrome {
    /// 应用到主窗口(可重复调用)。
    /// - Parameter window: 主窗口
    @MainActor
    static func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(kind)
            button?.isHidden = false
            // 标题栏透明后系统可能把容器淡出,红绿灯随之消失,这里强制保持可见
            button?.superview?.alphaValue = 1
        }
    }
}
