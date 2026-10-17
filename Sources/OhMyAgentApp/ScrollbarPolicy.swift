// @author ixxxxoooo
// 滚动条策略:把「外观 → 滚动条」设置应用到窗口内所有滚动视图。
// SwiftUI 侧用 `.scrollIndicators`;AppKit 侧(编辑器、文本视图、SwiftUI 底层的 NSScrollView)按需强制浮层/常驻样式。

import AppKit
import ChatKit
import SwiftUI

/// 遍历窗口并应用滚动条样式的执行器。
@MainActor
enum ScrollbarPolicy {
    /// 把设置应用到视图树里所有 `NSScrollView`。
    /// - Parameters:
    ///   - root: 起点视图(一般为窗口内容视图)
    ///   - visibility: 目标设置;`.system` 不做任何修改(沿用系统)
    static func apply(to root: NSView, visibility: ScrollbarVisibility) {
        switch visibility {
        case .custom:
            walk(root) { installCustomScrollers(in: $0) }
        case .system:
            // 跟随系统:只在之前装过自绘滚动条时还原成系统滚动条
            walk(root) { restoreSystemScrollers(in: $0) }
        case .autoHide, .always:
            let style: NSScroller.Style = visibility == .autoHide ? .overlay : .legacy
            walk(root) { scrollView in
                restoreSystemScrollers(in: scrollView)
                if scrollView.scrollerStyle != style { scrollView.scrollerStyle = style }
                scrollView.autohidesScrollers = visibility == .autoHide
            }
        }
    }

    /// 给滚动视图装上自绘滚动条(已装过则不重复设置)。
    private static func installCustomScrollers(in scrollView: NSScrollView) {
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        scrollView.autohidesScrollers = true
        if scrollView.hasVerticalScroller, !(scrollView.verticalScroller is OMScroller) {
            scrollView.verticalScroller = OMScroller()
        }
        if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is OMScroller) {
            scrollView.horizontalScroller = OMScroller()
        }
    }

    /// 把自绘滚动条换回系统滚动条。
    private static func restoreSystemScrollers(in scrollView: NSScrollView) {
        if scrollView.verticalScroller is OMScroller { scrollView.verticalScroller = NSScroller() }
        if scrollView.horizontalScroller is OMScroller { scrollView.horizontalScroller = NSScroller() }
    }

    /// 对单个滚动视图应用设置(AppKit 自绘视图创建时调用)。
    /// - Parameter scrollView: 目标滚动视图
    static func configure(_ scrollView: NSScrollView) {
        apply(to: scrollView, visibility: .current())
    }

    private static func walk(_ view: NSView, _ body: (NSScrollView) -> Void) {
        if let scroll = view as? NSScrollView { body(scroll) }
        for sub in view.subviews { walk(sub, body) }
    }
}

/// 放在窗口根部的执行器:设置变化或视图重绘时重新应用,并在非「跟随系统」时低频巡检新建的滚动视图。
private struct ScrollbarPolicyEnforcer: NSViewRepresentable {
    let visibility: ScrollbarVisibility

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.visibility = visibility
        context.coordinator.attach(to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var visibility: ScrollbarVisibility = .custom
        private weak var anchor: NSView?
        private var task: Task<Void, Never>?

        func attach(to view: NSView) {
            anchor = view
            enforce()
            task?.cancel()
            // 跟随系统不需要巡检;其余档位让新出现的滚动视图(切换标签、打开面板)在下一次巡检时被纳入
            guard visibility != .system else { return }
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.5))
                    self?.enforce()
                }
            }
        }

        private func enforce() {
            guard let root = anchor?.window?.contentView else { return }
            ScrollbarPolicy.apply(to: root, visibility: visibility)
        }

        deinit { task?.cancel() }
    }
}

extension View {
    /// 应用「外观 → 滚动条」设置:SwiftUI 滚动视图的指示器可见性 + AppKit 滚动视图的样式。
    func omScrollbarPolicy() -> some View { modifier(ScrollbarPolicyModifier()) }
}

private struct ScrollbarPolicyModifier: ViewModifier {
    @AppStorage(ClientPrefs.Key.scrollbarVisibility) private var raw = ScrollbarVisibility.custom.rawValue

    func body(content: Content) -> some View {
        let visibility = ScrollbarVisibility.resolve(raw)
        content
            .scrollIndicators(visibility == .always ? .visible : .automatic)
            .background(ScrollbarPolicyEnforcer(visibility: visibility))
    }
}
