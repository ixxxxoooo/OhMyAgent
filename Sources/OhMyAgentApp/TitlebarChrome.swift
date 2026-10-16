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
    /// 侧栏收起时,标签栏左侧需为浮层(回退/前进/侧栏开关 3 个按钮)预留的宽度:88 + 26×3 + 2×2 = 170(对齐 kuku)。
    /// 修改浮层按钮构成时必须同步此值。
    static let collapsedLeadingInset: CGFloat = trafficLightInset + buttonSize * 3 + buttonSpacing * 2
    /// 右栏开关占用的宽度(右栏头部与标签栏为其预留)。
    static let trailingInset: CGFloat = 34
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

/// 顶部浮层:左上「回退 / 前进 / 侧栏开关」,右上右栏开关。
/// 刻意做成整个工作区上的浮层(而不是塞进侧栏或标签栏):面板展开/收起时按钮坐标恒定,
/// 且不再被 NSSplitView 的列视图抢走点击(旧实现里左栏开关因此点不动)。
struct TitlebarOverlay: View {
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: TitlebarMetrics.buttonSpacing) {
                OverlayButton(icon: "arrow-left", label: String(localized: "回退"), enabled: workbench.nav.canGoBack) { workbench.goBack() }
                OverlayButton(icon: "arrow-right", label: String(localized: "前进"), enabled: workbench.nav.canGoForward) { workbench.goForward() }
                OverlayButton(
                    icon: "panel-left",
                    label: workbench.layout.leftVisible
                        ? String(localized: "隐藏左栏") + " (\(ShortcutStore.shared.binding(for: .toggleSidebar).display))"
                        : String(localized: "显示左栏") + " (\(ShortcutStore.shared.binding(for: .toggleSidebar).display))"
                ) { workbench.toggleLeft() }
            }
            .padding(.leading, TitlebarMetrics.trafficLightInset)
            Spacer(minLength: 0)
            OverlayButton(
                icon: "panel-right",
                label: workbench.layout.rightVisible
                    ? String(localized: "隐藏右栏") + " (\(ShortcutStore.shared.binding(for: .toggleInspector).display))"
                    : String(localized: "显示右栏") + " (\(ShortcutStore.shared.binding(for: .toggleInspector).display))"
            ) { workbench.toggleRight() }
            .padding(.trailing, 4)
        }
        .frame(height: TitlebarMetrics.height)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// 可拖动窗口的空白区域(放在背景层;命中时按下即拖动窗口,双击缩放)。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                super.mouseDown(with: event)
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
