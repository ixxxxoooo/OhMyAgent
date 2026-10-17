// @author ixxxxoooo
// 选择列表的锚点浮层:无箭头的轻量子窗口(NSPanel),贴着触发按钮弹出,可接收键盘(搜索框直接输入)。
// SwiftUI 的 `.popover` 在 macOS 上永远带箭头且键盘焦点常落在窗口外,因此选择类弹层统一走这里。

import AppKit
import ChatKit
import DesignSystem
import SwiftUI

/// 浮层相对触发按钮的位置。
enum PickerPlacement {
    /// 在按钮上方,左边缘对齐
    case above
    /// 在按钮上方,右边缘对齐
    case aboveTrailing
    /// 在按钮下方,左边缘对齐
    case below
    /// 在按钮下方,右边缘对齐
    case belowTrailing

    var isAbove: Bool { self == .above || self == .aboveTrailing }
    var isTrailing: Bool { self == .aboveTrailing || self == .belowTrailing }
}

/// 可成为 key 窗口的无边框面板(让搜索框能直接接收键盘输入)。
private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 浮层控制器:同一时刻只会有一个选择浮层。
@MainActor
final class PickerPanelController {
    static let shared = PickerPanelController()
    private var panel: PickerPanel?
    private weak var parent: NSWindow?
    private var anchorScreenRect: NSRect = .zero
    private var onClose: (() -> Void)?
    private var anchoredAbove = true
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// 卡片四周留给阴影的边距
    private let inset: CGFloat = 32

    /// 弹出浮层。
    /// - Parameters:
    ///   - anchor: 触发按钮所在视图
    ///   - placement: 位置
    ///   - width: 卡片宽度
    ///   - content: 卡片内容
    ///   - onClose: 浮层关闭回调(无论何种方式关闭)
    func present(anchor: NSView, placement: PickerPlacement, width: CGFloat, content: AnyView, onClose: @escaping () -> Void) {
        dismiss()
        guard let window = anchor.window else { onClose(); return }
        let inWindow = anchor.convert(anchor.bounds, to: nil)
        anchorScreenRect = window.convertToScreen(inWindow)
        self.onClose = onClose
        anchoredAbove = placement.isAbove
        parent = window

        let card = content.frame(width: width)
        let measured = NSHostingView(rootView: card).fittingSize
        let cardHeight = max(measured.height, 40)
        let panelSize = NSSize(width: width + inset * 2, height: cardHeight + inset * 2)

        let root = ZStack(alignment: placement.isAbove ? .bottom : .top) {
            Color.clear
            card
                .omGlassCard(cornerRadius: OMRadius.floating)
                .omFloatingShadow(cornerRadius: OMRadius.floating, yOffset: placement.isAbove ? -6 : 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    PickerPanelController.shared.cardHeightChanged(height)
                }
        }
        .padding(inset)
        .frame(width: panelSize.width)
        .frame(maxHeight: .infinity)

        let gap: CGFloat = 6
        var origin = NSPoint(
            x: (placement.isTrailing ? anchorScreenRect.maxX - width : anchorScreenRect.minX) - inset,
            y: placement.isAbove ? anchorScreenRect.maxY + gap - inset : anchorScreenRect.minY - gap + inset - panelSize.height
        )
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX - inset + 4), visible.maxX - panelSize.width + inset - 4)
            origin.y = min(max(origin.y, visible.minY - inset + 4), visible.maxY - panelSize.height + inset - 4)
        }

        let panel = PickerPanel(contentRect: NSRect(origin: origin, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.contentView = NSHostingView(rootView: root)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installMonitors()
    }

    /// 关闭浮层(幂等),并把键盘焦点还给父窗口。
    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        removeMonitors()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
        let callback = onClose
        onClose = nil
        callback?()
    }

    /// 卡片内容高度变化(搜索过滤、异步加载)时调整面板高度,贴着触发按钮的一侧保持不动。
    fileprivate func cardHeightChanged(_ cardHeight: CGFloat) {
        guard let panel, cardHeight > 1 else { return }
        let newHeight = cardHeight + inset * 2
        let frame = panel.frame
        guard abs(frame.height - newHeight) > 1 else { return }
        var next = frame
        next.size.height = newHeight
        // 下方弹出时顶边固定;上方弹出时底边固定
        if !anchoredAbove { next.origin.y = frame.maxY - newHeight }
        panel.setFrame(next, display: true)
    }

    private func installMonitors() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseDown(event) }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    /// 点击在浮层与触发按钮之外时关闭浮层。
    private func handleMouseDown(_ event: NSEvent) {
        guard let panel else { return }
        if event.window === panel { return }
        // 点在触发按钮上:交给按钮自己的开关逻辑(避免关了又立刻重开)
        let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        if anchorScreenRect.contains(location) { return }
        dismiss()
    }

    private func removeMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}

/// 记录触发按钮所在 NSView 的盒子。
@MainActor
private final class PickerAnchorBox {
    weak var view: NSView?
}

/// 放在触发按钮背后,取得它的 NSView 以便换算屏幕坐标。
private struct PickerAnchor: NSViewRepresentable {
    let box: PickerAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

/// 选择浮层修饰器。
private struct PickerPresenter<Item: PickListItem, Row: View>: ViewModifier {
    @Binding var isPresented: Bool
    let items: [Item]
    let selectedID: String?
    let placeholder: String
    let placement: PickerPlacement
    let width: CGFloat
    let showsSearch: Bool
    let maxListHeight: CGFloat
    let row: (Item) -> Row
    let onSelect: (Item) -> Void
    @State private var box = PickerAnchorBox()

    func body(content: Content) -> some View {
        content
            .background(PickerAnchor(box: box))
            .onChange(of: isPresented) { _, shown in
                if shown { present() } else { PickerPanelController.shared.dismiss() }
            }
            .task {
                // 初始即为展开(调试钩子)时,等锚点视图入窗后再弹出
                guard isPresented else { return }
                try? await Task.sleep(for: .milliseconds(300))
                if isPresented { present() }
            }
            .onDisappear { if isPresented { isPresented = false } }
    }

    private func present() {
        guard let anchor = box.view else { isPresented = false; return }
        let binding = $isPresented
        let content = AnyView(
            PickListContent(items: items, selectedID: selectedID, placeholder: placeholder, showsSearch: showsSearch, maxListHeight: maxListHeight,
                            row: row, onSelect: { item in
                                binding.wrappedValue = false
                                onSelect(item)
                            }, onDismiss: { binding.wrappedValue = false })
        )
        PickerPanelController.shared.present(anchor: anchor, placement: placement, width: width, content: content) {
            if binding.wrappedValue { binding.wrappedValue = false }
        }
    }
}

extension View {
    /// 在该视图(通常是一个按钮)上附加「无箭头、可搜索、可键盘操作」的选择浮层。
    /// - Parameters:
    ///   - isPresented: 是否展示;按钮点击时 toggle 即可
    ///   - items: 条目
    ///   - selectedID: 当前选中项(打勾 + 初始高亮)
    ///   - placeholder: 搜索框占位
    ///   - placement: 位置,默认按钮上方
    ///   - width: 卡片宽度
    ///   - showsSearch: 是否显示搜索框
    ///   - maxListHeight: 列表最大高度
    ///   - row: 行内容
    ///   - onSelect: 选中回调(浮层已自动关闭)
    func omPicker<Item: PickListItem, Row: View>(
        isPresented: Binding<Bool>, items: [Item], selectedID: String?, placeholder: String = String(localized: "搜索"),
        placement: PickerPlacement = .above, width: CGFloat = 260, showsSearch: Bool = true, maxListHeight: CGFloat = 300,
        @ViewBuilder row: @escaping (Item) -> Row, onSelect: @escaping (Item) -> Void
    ) -> some View {
        modifier(PickerPresenter(isPresented: isPresented, items: items, selectedID: selectedID, placeholder: placeholder, placement: placement,
                                 width: width, showsSearch: showsSearch, maxListHeight: maxListHeight, row: row, onSelect: onSelect))
    }

    /// 简单条目的便捷写法:`PickEntry`(标题 + 副标题 + 可选 Lucide 图标)。
    func omPicker(
        isPresented: Binding<Bool>, entries: [PickEntry], selectedID: String?, placeholder: String = String(localized: "搜索"),
        placement: PickerPlacement = .above, width: CGFloat = 220, showsSearch: Bool? = nil, maxListHeight: CGFloat = 300,
        onSelect: @escaping (PickEntry) -> Void
    ) -> some View {
        omPicker(isPresented: isPresented, items: entries, selectedID: selectedID, placeholder: placeholder, placement: placement,
                 width: width, showsSearch: showsSearch ?? (entries.count > 4), maxListHeight: maxListHeight, row: { entry in
            PickRowLabel(title: entry.title, subtitle: entry.subtitle) {
                if let icon = entry.icon { Image.om(icon, size: 13).foregroundStyle(OMColors.secondaryText) }
            }
        }, onSelect: onSelect)
    }
}

/// 自定义内容的浮层修饰器(内容自己负责搜索/键盘,如分支选择器)。
private struct CustomPickerPresenter<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let placement: PickerPlacement
    let width: CGFloat
    let panel: () -> Panel
    @State private var box = PickerAnchorBox()

    func body(content: Content) -> some View {
        content
            .background(PickerAnchor(box: box))
            .onChange(of: isPresented) { _, shown in
                if shown { present() } else { PickerPanelController.shared.dismiss() }
            }
            .task {
                // 初始即为展开(调试钩子)时,等锚点视图入窗后再弹出
                guard isPresented else { return }
                try? await Task.sleep(for: .milliseconds(300))
                if isPresented { present() }
            }
            .onDisappear { if isPresented { isPresented = false } }
    }

    private func present() {
        guard let anchor = box.view else { isPresented = false; return }
        let binding = $isPresented
        PickerPanelController.shared.present(anchor: anchor, placement: placement, width: width, content: AnyView(panel())) {
            if binding.wrappedValue { binding.wrappedValue = false }
        }
    }
}

extension View {
    /// 附加自定义内容的无箭头浮层(内容需自行处理键盘与关闭)。
    /// - Parameters:
    ///   - isPresented: 是否展示
    ///   - placement: 位置,默认按钮上方
    ///   - width: 卡片宽度
    ///   - content: 浮层内容
    func omCustomPicker<Panel: View>(isPresented: Binding<Bool>, placement: PickerPlacement = .above, width: CGFloat = 260,
                                     @ViewBuilder content: @escaping () -> Panel) -> some View {
        modifier(CustomPickerPresenter(isPresented: isPresented, placement: placement, width: width, panel: content))
    }
}
