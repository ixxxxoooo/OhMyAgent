// @author ixxxxoooo
// 自绘右键菜单 `omContextMenu`:替代系统 `.contextMenu`,样式与 Cursor 一致(圆角卡片 + 图标 + 快捷键 + 红色危险项)。
// 右键(或 ⌃ 点按)由本文件的事件监听统一捕获:命中最内层带菜单的视图,在鼠标位置弹出无箭头浮层;
// 支持 ↑↓ 选择、→ ← 展开/折叠子菜单、回车执行、Esc 关闭;子菜单以内联方式展开。

import AppKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI

// MARK: - 声明式写法

/// 菜单内容协议:`OMMenuItem` / `OMMenuDivider` / `OMMenuSubmenu` / `OMMenuHeader`。
protocol OMMenuContent {
    var menuEntries: [MenuEntry] { get }
}

/// 一个菜单项。
struct OMMenuItem: OMMenuContent {
    let title: String
    var icon: String?
    var shortcut: String?
    var isDestructive = false
    var isEnabled = true
    var isChecked: Bool?
    let action: @MainActor () -> Void

    /// - Parameters:
    ///   - title: 标题(字面量走本地化)
    ///   - icon: Lucide 图标语义名
    ///   - shortcut: 右侧快捷键提示
    ///   - isDestructive: 危险操作(红色)
    ///   - isEnabled: 是否可用
    ///   - isChecked: 非 nil 时显示勾选状态
    ///   - action: 点击/回车执行(菜单已先关闭)
    init(_ title: LocalizedStringResource, icon: String? = nil, shortcut: String? = nil, isDestructive: Bool = false, isEnabled: Bool = true,
         isChecked: Bool? = nil, action: @escaping @MainActor () -> Void) {
        self.title = String(localized: title)
        self.icon = icon
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.action = action
    }

    /// 已是运行时字符串的标题(如项目名、IDE 名),不再做本地化。
    init(verbatim title: String, icon: String? = nil, shortcut: String? = nil, isDestructive: Bool = false, isEnabled: Bool = true,
         isChecked: Bool? = nil, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.action = action
    }

    var menuEntries: [MenuEntry] {
        [MenuEntry(title: title, icon: icon, shortcut: shortcut, isDestructive: isDestructive, isEnabled: isEnabled, isChecked: isChecked, action: action)]
    }
}

/// 分隔线。
struct OMMenuDivider: OMMenuContent {
    var menuEntries: [MenuEntry] { [MenuEntry(kind: .divider)] }
}

/// 分组标题(不可选)。
struct OMMenuHeader: OMMenuContent {
    let title: String
    init(_ title: LocalizedStringResource) { self.title = String(localized: title) }
    var menuEntries: [MenuEntry] { [MenuEntry(kind: .header, title: title)] }
}

/// 子菜单(内联展开)。
struct OMMenuSubmenu: OMMenuContent {
    let title: String
    var icon: String?
    let children: [MenuEntry]

    init(_ title: LocalizedStringResource, icon: String? = nil, @OMMenuBuilder content: () -> [MenuEntry]) {
        self.title = String(localized: title)
        self.icon = icon
        self.children = content()
    }

    var menuEntries: [MenuEntry] { [MenuEntry(kind: .submenu(children), title: title, icon: icon)] }
}

/// 菜单构建器:支持 `if`、`if let`、`for`、嵌套数组。
@resultBuilder
enum OMMenuBuilder {
    static func buildExpression(_ content: any OMMenuContent) -> [MenuEntry] { content.menuEntries }
    static func buildExpression(_ entries: [MenuEntry]) -> [MenuEntry] { entries }
    static func buildBlock(_ parts: [MenuEntry]...) -> [MenuEntry] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [MenuEntry]?) -> [MenuEntry] { part ?? [] }
    static func buildEither(first: [MenuEntry]) -> [MenuEntry] { first }
    static func buildEither(second: [MenuEntry]) -> [MenuEntry] { second }
    static func buildArray(_ parts: [[MenuEntry]]) -> [MenuEntry] { parts.flatMap { $0 } }
}

extension View {
    /// 在该视图上附加自绘右键菜单(替代 `.contextMenu`)。
    /// - Parameter content: 菜单内容;每次右键时重新求值,因此总是反映最新状态
    func omContextMenu(@OMMenuBuilder _ content: @escaping () -> [MenuEntry]) -> some View {
        background(OMContextMenuAnchor(provider: content))
    }
}

// MARK: - 右键捕获

/// 菜单锚点视图:不拦截任何点击,只登记自己的位置与菜单提供者。
@MainActor
final class OMContextMenuAnchorView: NSView {
    var provider: (() -> [MenuEntry])?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { OMContextMenuCenter.shared.register(self) }
    }
}

private struct OMContextMenuAnchor: NSViewRepresentable {
    let provider: () -> [MenuEntry]

    func makeNSView(context: Context) -> OMContextMenuAnchorView {
        let view = OMContextMenuAnchorView()
        view.provider = provider
        return view
    }

    func updateNSView(_ nsView: OMContextMenuAnchorView, context: Context) { nsView.provider = provider }
}

/// 无边框可成为 key 的面板(接收键盘)。
private final class OMMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 右键菜单中心:统一监听鼠标事件并弹出菜单。
@MainActor
final class OMContextMenuCenter {
    static let shared = OMContextMenuCenter()

    private var anchors = WeakRegistry<OMContextMenuAnchorView>()
    private var monitor: Any?
    private var panel: OMMenuPanel?
    /// 上下文菜单当前是否正在展示
    var isPresented: Bool { panel != nil }
    private weak var parent: NSWindow?
    private var resignObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    /// 卡片四周留给阴影的边距
    private let inset: CGFloat = 24
    private var cardWidth: CGFloat = 220
    private var topLeft: NSPoint = .zero

    private init() {}

    /// 登记锚点并按需安装全局事件监听。
    func register(_ view: OMContextMenuAnchorView) {
        anchors.insert(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// 处理鼠标事件:返回 true 表示事件已被菜单消费。
    private func handle(_ event: NSEvent) -> Bool {
        if panel != nil {
            // 菜单展示中:面板内的事件放行;面板外的点击/滚动先关闭菜单
            if event.window === panel { return false }
            dismiss()
            if event.type == .leftMouseDown { return true }
            if event.type == .scrollWheel { return false }
        }
        let isContextClick = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isContextClick, let window = event.window, let anchor = innermostAnchor(at: event.locationInWindow, in: window) else { return false }
        let entries = MenuEntry.normalized(anchor.provider?() ?? [])
        guard !entries.isEmpty else { return false }
        present(entries: entries, in: window, at: window.convertPoint(toScreen: event.locationInWindow))
        return true
    }

    /// 命中点所在的最内层(面积最小、可见)锚点。
    private func innermostAnchor(at pointInWindow: NSPoint, in window: NSWindow) -> OMContextMenuAnchorView? {
        var best: (view: OMContextMenuAnchorView, area: CGFloat)?
        for view in anchors.alive() {
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { continue }
            let local = view.convert(pointInWindow, from: nil)
            guard view.bounds.contains(local), view.visibleRect.contains(local) else { continue }
            let area = view.bounds.width * view.bounds.height
            if let current = best, area >= current.area { continue }
            best = (view, area)
        }
        return best?.view
    }

    // MARK: 弹出与关闭

    func present(entries: [MenuEntry], in window: NSWindow, at screenPoint: NSPoint) {
        dismiss()
        parent = window
        let content = OMContextMenuCard(entries: entries, onDismiss: { OMContextMenuCenter.shared.dismiss() }, onHeight: { OMContextMenuCenter.shared.heightChanged($0) })
        let measured = NSHostingView(rootView: content.fixedSize(horizontal: true, vertical: false)).fittingSize
        cardWidth = min(max(measured.width, 200), 340)
        let cardHeight = max(measured.height, 40)
        let size = NSSize(width: cardWidth + inset * 2, height: cardHeight + inset * 2)

        let root = content
            .frame(width: cardWidth)
            .omGlassCard(cornerRadius: OMRadius.floating)
            .omFloatingShadow(cornerRadius: OMRadius.floating, yOffset: 6)
            .padding(inset)
            .frame(width: size.width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)

        topLeft = NSPoint(x: screenPoint.x - inset + 2, y: screenPoint.y + inset - 2)
        var origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX - inset + 4), visible.maxX - size.width + inset - 4)
            // 下方放不下时整体上移,保证菜单完整可见
            origin.y = max(origin.y, visible.minY - inset + 4)
            origin.y = min(origin.y, visible.maxY - size.height + inset - 4)
            topLeft.y = origin.y + size.height
        }
        let panel = OMMenuPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.contentView = NSHostingView(rootView: root)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    /// 关闭菜单(幂等),并把键盘焦点还给父窗口。
    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
    }

    /// 子菜单展开/折叠导致内容高度变化:顶边固定,调整面板高度。
    fileprivate func heightChanged(_ cardHeight: CGFloat) {
        guard let panel, cardHeight > 1 else { return }
        let newHeight = cardHeight + inset * 2
        guard abs(panel.frame.height - newHeight) > 1 else { return }
        var next = panel.frame
        next.size.height = newHeight
        next.origin.y = topLeft.y - newHeight
        if let visible = (parent?.screen ?? NSScreen.main)?.visibleFrame, next.origin.y < visible.minY - inset + 4 {
            next.origin.y = visible.minY - inset + 4
        }
        panel.setFrame(next, display: true)
    }
}

// MARK: - 卡片

/// 菜单卡片:行 + 键盘导航。
struct OMContextMenuCard: View {
    @State private var state: ContextMenuState
    let onDismiss: () -> Void
    let onHeight: (CGFloat) -> Void
    @FocusState private var focused: Bool

    init(entries: [MenuEntry], onDismiss: @escaping () -> Void, onHeight: @escaping (CGFloat) -> Void) {
        _state = State(initialValue: ContextMenuState(entries: entries))
        self.onDismiss = onDismiss
        self.onHeight = onHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.rows) { row in
                rowView(row)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 200, alignment: .leading)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { state.move(-1); return .handled }
        .onKeyPress(.downArrow) { state.move(1); return .handled }
        .onKeyPress(.rightArrow) { state.expandHighlighted(); return .handled }
        .onKeyPress(.leftArrow) { state.collapseHighlighted(); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onKeyPress(.return) { activate(nil); return .handled }
        .onGeometryChange(for: CGFloat.self) { $0.size.height + 0 } action: { onHeight($0) }
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            focused = true
        }
        .accessibilityElement(children: .contain)
    }

    /// 执行条目:菜单先关闭,再在下一个主线程周期运行动作(动作里可能弹出对话框)。
    private func activate(_ id: String?) {
        switch state.activate(id) {
        case .run(let action):
            onDismiss()
            DispatchQueue.main.async { action() }
        case .toggled, .none:
            break
        }
    }

    @ViewBuilder
    private func rowView(_ row: MenuRow) -> some View {
        let entry = row.entry
        switch entry.kind {
        case .divider:
            Rectangle().fill(OMColors.hairline).frame(height: 0.5).padding(.vertical, 4).padding(.horizontal, 8)
        case .header:
            Text(verbatim: entry.title).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 2)
        case .item, .submenu:
            itemRow(row)
        }
    }

    private func itemRow(_ row: MenuRow) -> some View {
        let entry = row.entry
        let highlighted = state.highlightedID == entry.id
        let isSubmenu: Bool = { if case .submenu = entry.kind { return true } else { return false } }()
        let tint: Color = entry.isDestructive ? OMColors.danger : OMColors.primaryText
        return HStack(spacing: 8) {
            Group {
                if let icon = entry.icon {
                    Image.om(icon, size: 13).foregroundStyle(entry.isDestructive ? OMColors.danger : OMColors.secondaryText)
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 16)
            Text(verbatim: entry.title).font(OMFonts.small).foregroundStyle(tint).lineLimit(1)
            Spacer(minLength: 16)
            if let shortcut = entry.shortcut {
                Text(verbatim: shortcut).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            }
            if entry.isChecked == true { Image.om("check", size: 12).foregroundStyle(OMColors.accent) }
            if isSubmenu {
                Image.om(state.expanded.contains(entry.id) ? "chevron-down" : "chevron-right", size: 11).foregroundStyle(OMColors.tertiaryText)
            }
        }
        .padding(.leading, 8 + CGFloat(row.depth) * 14)
        .padding(.trailing, 8)
        .frame(minHeight: 28)
        .background(highlighted ? OMColors.pressedFill : Color.clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
        .padding(.horizontal, 4)
        .opacity(entry.isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onHover { inside in if inside { state.highlight(entry.id) } }
        .onTapGesture { activate(entry.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(.isButton)
    }
}
