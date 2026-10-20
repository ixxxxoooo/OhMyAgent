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
    /// - Returns: 本次实际改动了多少个滚动视图(0 表示视图树已处于目标状态)
    @discardableResult
    static func apply(to root: NSView, visibility: ScrollbarVisibility) -> Int {
        var changed = 0
        switch visibility {
        case .custom:
            walk(root) { if installCustomScrollers(in: $0) { changed += 1 } }
        case .system:
            // 跟随系统:只在之前装过自绘滚动条时还原成系统滚动条
            walk(root) { if restoreSystemScrollers(in: $0) { changed += 1 } }
        case .autoHide, .always:
            let style: NSScroller.Style = visibility == .autoHide ? .overlay : .legacy
            walk(root) { scrollView in
                var touched = restoreSystemScrollers(in: scrollView)
                if scrollView.scrollerStyle != style { scrollView.scrollerStyle = style; touched = true }
                if scrollView.autohidesScrollers != (visibility == .autoHide) { scrollView.autohidesScrollers = visibility == .autoHide; touched = true }
                if touched { changed += 1 }
            }
        }
        return changed
    }

    /// 给滚动视图装上自绘滚动条(已装过则不重复设置)。
    /// - Returns: 是否做了改动
    private static func installCustomScrollers(in scrollView: NSScrollView) -> Bool {
        var changed = false
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay; changed = true }
        if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true; changed = true }
        if scrollView.hasVerticalScroller, !(scrollView.verticalScroller is OMScroller) {
            scrollView.verticalScroller = OMScroller()
            changed = true
        }
        if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is OMScroller) {
            scrollView.horizontalScroller = OMScroller()
            changed = true
        }
        return changed
    }

    /// 把自绘滚动条换回系统滚动条。
    /// - Returns: 是否做了改动
    private static func restoreSystemScrollers(in scrollView: NSScrollView) -> Bool {
        var changed = false
        if scrollView.verticalScroller is OMScroller { scrollView.verticalScroller = NSScroller(); changed = true }
        if scrollView.horizontalScroller is OMScroller { scrollView.horizontalScroller = NSScroller(); changed = true }
        return changed
    }

    /// 对单个滚动视图应用设置(AppKit 自绘视图创建时调用)。
    /// - Parameter scrollView: 目标滚动视图
    static func configure(_ scrollView: NSScrollView) {
        apply(to: scrollView, visibility: .current())
    }

    private static func walk(_ view: NSView, _ body: (NSScrollView) -> Void) {
        // 表格等常驻滚动条的叶子自行管理样式(需始终可见),不受「滚动条」外观设置改写
        if let scroll = view as? NSScrollView, (scroll as? OMLeafScrollView)?.persistentScroller != true { body(scroll) }
        for sub in view.subviews { walk(sub, body) }
    }
}

/// 放在窗口根部的执行器:设置变化或视图重绘时重新应用;非「跟随系统」时,新出现的滚动视图(切换标签、打开面板)
/// 由用户操作(鼠标抬起/按键)触发的去抖检查纳入,另有指数退避的低频兜底巡检(视图树稳定后最长 30 秒一次,不再固定 1.5 秒遍历)。
private struct ScrollbarPolicyEnforcer: NSViewRepresentable {
    let visibility: ScrollbarVisibility

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // 锚点与设置都没变就不重新 attach:attach 会遍历整个窗口视图树,而 updateNSView 随根视图每次重算都会调用;
        // 新出现的滚动视图由鼠标抬起/按键触发的去抖检查与低频巡检纳入
        guard !context.coordinator.isAttached(to: view, visibility: visibility) else { return }
        context.coordinator.visibility = visibility
        context.coordinator.attach(to: view)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var visibility: ScrollbarVisibility = .custom
        private weak var anchor: NSView?
        private var patrol: Task<Void, Never>?
        private var settle: Task<Void, Never>?
        private var monitor: Any?
        /// 兜底巡检当前间隔(秒);发现需要改动的滚动视图时回到最短,否则逐步放大
        private var interval = Coordinator.minInterval
        private static let minInterval = 1.5
        private static let maxInterval = 30.0

        /// 是否已经以相同的锚点与设置装好(此时无需再 attach)。
        func isAttached(to view: NSView, visibility: ScrollbarVisibility) -> Bool {
            anchor === view && self.visibility == visibility && (visibility == .system || monitor != nil)
        }

        func attach(to view: NSView) {
            anchor = view
            interval = Self.minInterval
            enforce()
            stop()
            // 跟随系统不需要巡检
            guard visibility != .system else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyUp]) { [weak self] event in
                self?.userActed()
                return event
            }
            startPatrol()
        }

        /// 停止巡检与事件监听(设置切到跟随系统或视图销毁时)。
        func stop() {
            patrol?.cancel()
            patrol = nil
            settle?.cancel()
            settle = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// 用户操作后稍等视图树落定再检查一次;连续操作合并为一次,并让兜底巡检回到较短间隔。
        private func userActed() {
            settle?.cancel()
            settle = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }
                self.enforce()
                self.interval = Self.minInterval
            }
        }

        private func startPatrol() {
            patrol = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    try? await Task.sleep(for: .seconds(self.interval))
                    guard !Task.isCancelled else { return }
                    self.interval = self.enforce() > 0 ? Self.minInterval : min(self.interval * 2, Self.maxInterval)
                }
            }
        }

        /// 应用设置到整个窗口;返回改动的滚动视图数。
        @discardableResult
        private func enforce() -> Int {
            guard let root = anchor?.window?.contentView else { return 0 }
            return ScrollbarPolicy.apply(to: root, visibility: visibility)
        }

        deinit {
            patrol?.cancel()
            settle?.cancel()
        }
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
