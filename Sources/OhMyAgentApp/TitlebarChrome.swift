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
    /// 左上浮层固定按钮数:搜索、回退、前进(面板开关另计)。
    static let fixedLeftButtons = 3
    /// 侧栏收起时左上浮层的固定按钮数:搜索、新对话(回退/前进隐藏,只留快捷键)。
    static let collapsedLeftButtons = 2
    /// 左上浮层(红绿灯让位 + `toggles` 个面板开关 + 搜索/回退/前进)的总宽度:`toggles == 1` 时为 198(对齐 Cursor 的
    /// 「红绿灯 → 侧栏开关 → 搜索 → 后退 → 前进」)。修改浮层按钮构成时必须同步此函数。
    static func leftClusterWidth(toggles: Int, collapsed: Bool = false) -> CGFloat {
        let count = (collapsed ? collapsedLeftButtons : fixedLeftButtons) + toggles
        return trafficLightInset + buttonSize * CGFloat(count) + buttonSpacing * CGFloat(count - 1)
    }

    /// 模式切换按钮(Agent 窗口的「编辑器 ↗」、IDE 窗口的「Agents Window ↗」)的宽度:两个窗口共用同一个值,
    /// 标题栏右侧簇在两个窗口间切换时不跳动。
    static let modeSwitchWidth: CGFloat = 124

    /// 右上浮层(`toggles` 个面板开关 + 边距)占用的宽度:`toggles == 1` 时为 34;没有开关时为 0。
    /// - Parameters:
    ///   - toggles: 面板开关个数
    ///   - includesModeSwitch: 是否含最外侧的模式切换按钮(Agent 窗口为 true)
    static func rightClusterWidth(toggles: Int, includesModeSwitch: Bool = false) -> CGFloat {
        let count = max(toggles, 0)
        guard includesModeSwitch else {
            return count == 0 ? 0 : buttonSize * CGFloat(count) + buttonSpacing * CGFloat(count - 1) + 8
        }
        // 面板开关(各 buttonSize)+ 模式切换按钮,按钮之间 buttonSpacing,外加 8 的右边距
        return buttonSize * CGFloat(count) + modeSwitchWidth + buttonSpacing * CGFloat(count) + 8
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
                .background(hovering && enabled ? OMColors.pressedFill : .clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? OMColors.secondaryText : OMColors.tertiaryText.opacity(0.6))
        .onHover { hovering = $0 }
        .omTooltip(label)
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
                // 对齐 Cursor:红绿灯 → 侧栏开关 → 搜索 → 回退 → 前进
                ForEach(toggles(on: .left)) { toggleButton($0, side: .left) }
                OverlayButton(icon: "search", label: String(localized: "搜索") + " (\(ShortcutStore.shared.binding(for: .hubSearch).display))") {
                    HubModel.shared.present(.all, workbench: workbench)
                }
                if workbench.layout.visibleColumns(on: .left).isEmpty {
                    // 侧栏收起:「+」放在搜索右边,回退/前进隐藏(仅保留快捷键)
                    OverlayButton(
                        icon: "plus",
                        label: String(localized: "新对话") + " (\(ShortcutStore.shared.binding(for: .newConversation).display))",
                        enabled: workbench.selectedProjectID != nil
                    ) {
                        if let id = workbench.selectedProjectID { workbench.newConversation(in: id) }
                    }
                } else {
                    OverlayButton(
                        icon: "arrow-left",
                        label: String(localized: "回退") + " (\(ShortcutStore.shared.binding(for: .goBack).display))",
                        enabled: workbench.nav.canGoBack
                    ) { workbench.goBack() }
                    OverlayButton(
                        icon: "arrow-right",
                        label: String(localized: "前进") + " (\(ShortcutStore.shared.binding(for: .goForward).display))",
                        enabled: workbench.nav.canGoForward
                    ) { workbench.goForward() }
                }
            }
            .padding(.leading, TitlebarMetrics.trafficLightInset)
            Spacer(minLength: 0)
            HStack(spacing: TitlebarMetrics.buttonSpacing) {
                // 右侧由内向外:工具栏在项目栏内侧
                ForEach(toggles(on: .right).reversed()) { column in
                    // 「扩展」按钮紧贴工具栏开关的内侧,只在右栏打开时显示
                    if column == .tools, workbench.layout.isVisible(.tools) { expandButton }
                    toggleButton(column, side: .right)
                }
                // 最外侧:切到 IDE 窗口(⌃⌘I;⌥ 点击新开窗口)
                ModeSwitchButton(target: .ide)
            }
            .padding(.trailing, 8)
        }
        .frame(height: TitlebarMetrics.height)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// 右栏「扩展」按钮:右栏覆盖中栏,占满项目栏以外的全部宽度;再点还原。
    private var expandButton: some View {
        let expanded = workbench.rightExpanded
        return OverlayButton(
            icon: expanded ? "minimize-2" : "maximize-2",
            label: expanded ? String(localized: "还原") : String(localized: "扩展全屏")
        ) { workbench.rightExpanded.toggle() }
    }

    /// 某一侧的面板开关(项目栏、工具栏),由外向内。
    private func toggles(on side: PanelSide) -> [PanelColumn] {
        workbench.layout.columns(on: side).filter { $0 == .sidebar || $0 == .tools }
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
        let side = side(of: column)
        guard column != .sidebar, visibleColumns(on: side).first == column else { return (0, 0) }
        return side == .left
            ? (TitlebarMetrics.leftClusterWidth(toggles: toggleCount(on: .left)), 0)
            : (0, TitlebarMetrics.rightClusterWidth(toggles: toggleCount(on: .right) + (column == .tools ? 1 : 0), includesModeSwitch: true))
    }
}

/// 可拖动窗口的空白区域(放在背景层;命中时按下即拖动窗口,双击缩放)。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // 窗口默认不可被「按下即拖动」(见 WindowChrome.apply),仅在这里临时放开,拖动结束后恢复
            window.isMovable = true
            defer { window.isMovable = false }
            if event.clickCount == 2 {
                window.performZoom(nil)
            } else {
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
        // 标签、面板标题等可拖拽元素落在标题栏高度内,系统会把按下当成拖动窗口;窗口只通过 WindowDragArea 显式拖动
        window.isMovable = false
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

/// 鼠标侧键导航:侧键后退(按键编号 3)/前进(按键编号 4),与浏览器、VS Code 一致。
@MainActor
enum MouseNavigationMonitor {
    private static var token: Any?

    /// 安装全局(本应用内)侧键监视器,幂等。
    /// - Parameter workbench: 工作台
    static func install(workbench: WorkbenchModel) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard workbench.mode == .workspace else { return false }
                switch event.buttonNumber {
                case 3: workbench.goBack(); return true
                case 4: workbench.goForward(); return true
                default: return false
                }
            }
            return handled ? nil : event
        }
    }
}

extension View {
    /// 让该区域像 `WindowDragArea` 一样可拖动窗口、双击缩放,但走 SwiftUI 手势:
    /// 外层有 `contentShape` + 点击手势时 SwiftUI 会吞掉命中,背景里的 NSView 收不到按下(如标签栏空白处)。
    func windowDragGesture() -> some View {
        modifier(WindowDragGesture())
    }
}

private struct WindowDragGesture: ViewModifier {
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global).onChanged { _ in
                guard let window = NSApp.keyWindow, let event = NSApp.currentEvent else { return }
                window.isMovable = true
                defer { window.isMovable = false }
                window.performDrag(with: event)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { NSApp.keyWindow?.performZoom(nil) })
    }
}
