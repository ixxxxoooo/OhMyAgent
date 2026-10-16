// @author ixxxxoooo
// Mermaid 悬浮预览:点击聊天里的图表后,在当前窗口内以悬浮窗展示(不再新开标签页)。
// - 标题栏可拖动整个悬浮窗,四边与四角可缩放窗口;
// - 图表区支持拖动平移、触控板双指平移、捏合/⌘+滚轮/鼠标滚轮缩放、双击在「适应窗口」与 100% 之间切换;
// - 按钮全部为图标:缩小、放大、适应窗口、查看源码、复制、下载(PNG/PDF/源码)、关闭。

import AppKit
import DesignSystem
import IconKit
import MermaidKit
import SwiftUI

/// 悬浮预览的显示状态(全局唯一一个悬浮窗)。
@MainActor
@Observable
final class MermaidFloatingStore {
    static let shared = MermaidFloatingStore()

    /// 一次展示的内容。
    struct Item: Equatable {
        let id = UUID()
        let source: String
    }

    /// 当前展示的图表;nil 表示关闭
    private(set) var item: Item?
    /// 悬浮窗在窗口内的位置与大小(关闭后保留,下次打开沿用)
    var frame: CGRect?

    /// 打开悬浮预览。
    /// - Parameter source: Mermaid 源码(为空时忽略)
    func present(source: String) {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        item = Item(source: source)
    }

    /// 关闭悬浮预览。
    func dismiss() { item = nil }
}

/// 悬浮窗几何计算(纯函数,便于测试)。
enum FloatingPanelGeometry {
    /// 最小尺寸。
    static let minSize = CGSize(width: 420, height: 300)

    /// 缩放手柄所在的边/角。
    enum Handle: CaseIterable {
        case top, bottom, leading, trailing, topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    /// 首次打开的默认位置:居中,大小约为容器的 72% × 78%(有上限)。
    static func initialFrame(in container: CGSize) -> CGRect {
        let width = min(max(container.width * 0.72, minSize.width), 980)
        let height = min(max(container.height * 0.78, minSize.height), 720)
        return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2, width: width, height: height).clamped(to: container)
    }

    /// 平移后的位置:标题栏始终保留在容器内(至少露出 80pt 宽、整条标题栏高度)。
    static func moved(_ frame: CGRect, by translation: CGSize, in container: CGSize, headerHeight: CGFloat) -> CGRect {
        var next = frame.offsetBy(dx: translation.width, dy: translation.height)
        let keep: CGFloat = 80
        next.origin.x = min(max(next.origin.x, keep - next.width), container.width - keep)
        next.origin.y = min(max(next.origin.y, 0), max(container.height - headerHeight, 0))
        return next
    }

    /// 拖动手柄后的新窗口框:不小于最小尺寸,不超出容器。
    static func resized(_ frame: CGRect, handle: Handle, by t: CGSize, in container: CGSize) -> CGRect {
        var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
        switch handle {
        case .leading, .topLeading, .bottomLeading: minX += t.width
        case .trailing, .topTrailing, .bottomTrailing: maxX += t.width
        default: break
        }
        switch handle {
        case .top, .topLeading, .topTrailing: minY += t.height
        case .bottom, .bottomLeading, .bottomTrailing: maxY += t.height
        default: break
        }
        // 先限制最小尺寸(被拖动的那一侧让位),再限制在容器内
        if maxX - minX < minSize.width {
            if [.leading, .topLeading, .bottomLeading].contains(handle) { minX = maxX - minSize.width } else { maxX = minX + minSize.width }
        }
        if maxY - minY < minSize.height {
            if [.top, .topLeading, .topTrailing].contains(handle) { minY = maxY - minSize.height } else { maxY = minY + minSize.height }
        }
        minX = max(minX, 0); minY = max(minY, 0)
        maxX = min(maxX, container.width); maxY = min(maxY, container.height)
        return CGRect(x: minX, y: minY, width: max(maxX - minX, minSize.width), height: max(maxY - minY, minSize.height))
    }
}

extension CGRect {
    /// 把矩形整体挪进容器(尺寸超出时先缩小)。
    func clamped(to container: CGSize) -> CGRect {
        let w = min(width, container.width), h = min(height, container.height)
        return CGRect(x: min(max(minX, 0), container.width - w), y: min(max(minY, 0), container.height - h), width: w, height: h)
    }
}

/// 悬浮预览的覆盖层:放在工作台最上层,只有悬浮窗本身接收点击,其余区域穿透到下方界面。
struct MermaidFloatingOverlay: View {
    private let store = MermaidFloatingStore.shared

    var body: some View {
        GeometryReader { proxy in
            if let item = store.item {
                MermaidFloatingPanel(item: item, container: proxy.size, store: store)
                    .id(item.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(omAnimation(.snappy(duration: 0.18)), value: store.item)
    }

    /// 遵循「减弱动态效果」的动画。
    private func omAnimation(_ animation: Animation) -> Animation? {
        omShouldReduceMotion() ? nil : animation
    }
}

/// 悬浮窗本体:标题栏 + 图表视口 + 缩放手柄。
private struct MermaidFloatingPanel: View {
    let item: MermaidFloatingStore.Item
    let container: CGSize
    let store: MermaidFloatingStore

    @Environment(\.colorScheme) private var scheme
    @State private var frame: CGRect = .zero
    @State private var result: MermaidResult?
    @State private var viewport = MermaidViewport()
    @State private var canvasSize: CGSize = .zero
    /// 用户未手动缩放/平移时,窗口大小变化会自动重新适应
    @State private var autoFit = true
    @State private var showSource = false
    @State private var copied = false
    @State private var moveStart: CGRect?
    @State private var resizeStart: CGRect?

    private let headerHeight: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: frame.width, height: frame.height)
        .background(OMColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 1))
        .overlay { resizeHandles }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 8)
        .position(x: frame.midX, y: frame.midY)
        .onAppear {
            frame = (store.frame ?? FloatingPanelGeometry.initialFrame(in: container)).clamped(to: container)
        }
        .onChange(of: container) { _, size in frame = frame.clamped(to: size) }
        .onChange(of: frame) { _, value in store.frame = value }
        .task(id: item.id) { result = await renderMermaid(item.source) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mermaid 图表预览")
    }

    // MARK: 标题栏

    private var header: some View {
        HStack(spacing: 2) {
            Image.om("workflow", size: 13)
                .foregroundStyle(OMColors.secondaryText)
                .padding(.horizontal, 6)
            Text("Mermaid")
                .font(OMFonts.small.weight(.medium))
                .foregroundStyle(OMColors.secondaryText)
            Spacer(minLength: 8)
            if case .scene = result {
                if !showSource {
                    iconButton("zoom-out", help: "缩小") { zoom(by: 1 / 1.25) }
                    Text(viewport.percentText)
                        .font(OMFonts.caption.monospacedDigit())
                        .foregroundStyle(OMColors.tertiaryText)
                        .frame(width: 44)
                    iconButton("zoom-in", help: "放大") { zoom(by: 1.25) }
                    iconButton("scan", help: "适应窗口") { fitToWindow() }
                    separator
                }
                iconButton("code", help: showSource ? "查看图" : "查看源码", active: showSource) { showSource.toggle() }
                iconButton(copied ? "check" : "copy", help: showSource ? "复制源码" : "复制图片") { copy() }
                downloadMenu
                separator
            }
            iconButton("x", help: "关闭") { store.dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 8)
        .frame(height: headerHeight)
        .background(OMColors.surface)
        .contentShape(Rectangle())
        .gesture(moveGesture)
        .onTapGesture(count: 2) { fitToWindow() }
    }

    private var separator: some View {
        Rectangle().fill(OMColors.hairline).frame(width: 1, height: 16).padding(.horizontal, 4)
    }

    /// 纯图标按钮(悬停底色 + 提示)。
    private func iconButton(_ icon: String, help: LocalizedStringKey, active: Bool = false, action: @escaping () -> Void) -> some View {
        FloatingIconButton(icon: icon, help: help, active: active, action: action)
    }

    /// 下载菜单:图标按钮,下拉选择格式。
    private var downloadMenu: some View {
        Menu {
            ForEach(MermaidExportFormat.allCases, id: \.self) { format in
                Button(format.title) { download(format) }
            }
        } label: {
            Image.om("download", size: 14)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(OMColors.secondaryText)
        .fixedSize()
        .help("下载")
        .accessibilityLabel("下载")
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch result {
        case .none:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scene(let scene, _):
            if showSource {
                ScrollView([.horizontal, .vertical]) {
                    Text(item.source)
                        .font(OMFonts.readingMono)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(OMColors.surface)
            } else {
                MermaidViewportView(
                    scene: scene,
                    dark: scheme == .dark,
                    viewport: $viewport,
                    onUserInteraction: { autoFit = false },
                    onSizeChange: { size in
                        canvasSize = size
                        if autoFit { viewport.fit(scene: scene.size, in: size) }
                    },
                    onToggleFit: { toggleFit(scene) },
                    onClose: { store.dismiss() }
                )
            }
        case .failure(let error):
            VStack(alignment: .leading, spacing: 8) {
                Label("无法渲染此图:\(error.description)", om: "exclamationmark.triangle")
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.warning)
                ScrollView([.horizontal, .vertical]) {
                    Text(item.source).font(OMFonts.readingMono).textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: 动作

    private var currentScene: MScene? {
        if case .scene(let scene, _) = result { return scene }
        return nil
    }

    private func zoom(by factor: Double) {
        autoFit = false
        viewport.zoom(by: factor, anchor: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    private func fitToWindow() {
        guard let scene = currentScene else { return }
        autoFit = true
        viewport.fit(scene: scene.size, in: canvasSize)
    }

    /// 双击:适应窗口 ⇄ 100%。
    private func toggleFit(_ scene: MScene) {
        var fitted = MermaidViewport()
        fitted.fit(scene: scene.size, in: canvasSize)
        if abs(viewport.scale - fitted.scale) < 0.01 {
            autoFit = false
            viewport.actualSize(scene: scene.size, in: canvasSize)
        } else {
            autoFit = true
            viewport = fitted
        }
    }

    private func copy() {
        if showSource || currentScene == nil {
            MermaidExport.copySource(item.source)
        } else if let scene = currentScene {
            MermaidExport.copyImage(scene: scene, source: item.source, dark: scheme == .dark)
        }
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    private func download(_ format: MermaidExportFormat) {
        guard let scene = currentScene else { return }
        MermaidExport.save(format, scene: scene, source: item.source, dark: scheme == .dark)
    }

    // MARK: 手势

    /// 拖动标题栏移动悬浮窗(用全局坐标系,避免窗口移动时手势坐标抖动)。
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if moveStart == nil { moveStart = frame }
                guard let start = moveStart else { return }
                frame = FloatingPanelGeometry.moved(start, by: value.translation, in: container, headerHeight: headerHeight)
            }
            .onEnded { _ in moveStart = nil }
    }

    /// 四边四角的缩放手柄(透明热区,鼠标移上去显示对应光标)。
    private var resizeHandles: some View {
        ZStack {
            ForEach(FloatingPanelGeometry.Handle.allCases, id: \.self) { handle in
                ResizeHandleView(handle: handle)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if resizeStart == nil { resizeStart = frame }
                                guard let start = resizeStart else { return }
                                frame = FloatingPanelGeometry.resized(start, handle: handle, by: value.translation, in: container)
                            }
                            .onEnded { _ in resizeStart = nil }
                    )
            }
        }
    }
}

/// 标题栏图标按钮。
struct FloatingIconButton: View {
    let icon: String
    let help: LocalizedStringKey
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image.om(icon, size: 14)
                .frame(width: 28, height: 26)
                .background(
                    (active ? OMColors.accent.opacity(0.16) : (hovering ? Color.primary.opacity(0.08) : Color.clear)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? OMColors.accent : OMColors.secondaryText)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// 单个缩放手柄的热区与光标。
private struct ResizeHandleView: View {
    let handle: FloatingPanelGeometry.Handle
    private let thickness: CGFloat = 8
    private let corner: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .frame(width: size(in: proxy).width, height: size(in: proxy).height)
                .onHover { inside in
                    if inside { cursor.push() } else { NSCursor.pop() }
                }
                .position(center(in: proxy))
        }
    }

    private func size(in proxy: GeometryProxy) -> CGSize {
        switch handle {
        case .top, .bottom: return CGSize(width: proxy.size.width - corner * 2, height: thickness)
        case .leading, .trailing: return CGSize(width: thickness, height: proxy.size.height - corner * 2)
        default: return CGSize(width: corner, height: corner)
        }
    }

    private func center(in proxy: GeometryProxy) -> CGPoint {
        let w = proxy.size.width, h = proxy.size.height
        switch handle {
        case .top: return CGPoint(x: w / 2, y: thickness / 2)
        case .bottom: return CGPoint(x: w / 2, y: h - thickness / 2)
        case .leading: return CGPoint(x: thickness / 2, y: h / 2)
        case .trailing: return CGPoint(x: w - thickness / 2, y: h / 2)
        case .topLeading: return CGPoint(x: corner / 2, y: corner / 2)
        case .topTrailing: return CGPoint(x: w - corner / 2, y: corner / 2)
        case .bottomLeading: return CGPoint(x: corner / 2, y: h - corner / 2)
        case .bottomTrailing: return CGPoint(x: w - corner / 2, y: h - corner / 2)
        }
    }

    /// 对应的系统窗口缩放光标。
    private var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch handle {
        case .top: position = .top
        case .bottom: position = .bottom
        case .leading: position = .left
        case .trailing: position = .right
        case .topLeading: position = .topLeft
        case .topTrailing: position = .topRight
        case .bottomLeading: position = .bottomLeft
        case .bottomTrailing: position = .bottomRight
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }
}

// MARK: - 视口

/// 图表视口:Canvas 绘制 + AppKit 事件层(拖动、滚轮、捏合、双击、键盘)。
private struct MermaidViewportView: View {
    let scene: MScene
    let dark: Bool
    @Binding var viewport: MermaidViewport
    let onUserInteraction: () -> Void
    let onSizeChange: (CGSize) -> Void
    let onToggleFit: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    var body: some View {
        let palette = MermaidPalette(dark: dark)
        ZStack {
            palette.background
            Canvas { ctx, _ in
                var c = ctx
                c.translateBy(x: viewport.offset.x, y: viewport.offset.y)
                c.scaleBy(x: viewport.scale, y: viewport.scale)
                MermaidRenderer.draw(scene, in: &c, palette: palette)
            }
            MermaidInteractionLayer(
                onPan: { delta in onUserInteraction(); viewport.pan(by: delta) },
                onZoom: { factor, anchor in onUserInteraction(); viewport.zoom(by: factor, anchor: anchor) },
                onDoubleClick: onToggleFit,
                onClose: onClose
            )
        }
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
    }
}

/// 事件层:接管鼠标/触控板/键盘,转成平移与缩放回调。
struct MermaidInteractionLayer: NSViewRepresentable {
    let onPan: @MainActor (CGPoint) -> Void
    let onZoom: @MainActor (Double, CGPoint) -> Void
    let onDoubleClick: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    /// 单击(未拖动)回调,参数为视口坐标;灯箱用它实现「点空白处关闭」
    var onClick: (@MainActor (CGPoint) -> Void)?

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: EventView, context: Context) { apply(to: nsView) }

    private func apply(to view: EventView) {
        view.onPan = onPan
        view.onZoom = onZoom
        view.onDoubleClick = onDoubleClick
        view.onClose = onClose
        view.onClick = onClick
    }

    final class EventView: NSView {
        var onPan: (@MainActor (CGPoint) -> Void)?
        var onZoom: (@MainActor (Double, CGPoint) -> Void)?
        var onDoubleClick: (@MainActor () -> Void)?
        var onClose: (@MainActor () -> Void)?
        var onClick: (@MainActor (CGPoint) -> Void)?
        private var moved = false
        private var lastPoint: CGPoint?
        private var dragging = false
        /// 打开前的第一响应者:关闭后还给它(通常是输入框)
        private weak var previousResponder: NSResponder?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            previousResponder = window.firstResponder
            // 下一轮再抢焦点,避免与 SwiftUI 的布局过程冲突
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let window, window.firstResponder === self {
                window.makeFirstResponder(previousResponder)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand)
        }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            if event.clickCount == 2 {
                MainActor.assumeIsolated { onDoubleClick?() }
                return
            }
            dragging = true
            moved = false
            lastPoint = point(event)
            window?.invalidateCursorRects(for: self)
        }

        override func mouseDragged(with event: NSEvent) {
            let current = point(event)
            guard let last = lastPoint else { lastPoint = current; return }
            lastPoint = current
            moved = true
            let delta = CGPoint(x: current.x - last.x, y: current.y - last.y)
            MainActor.assumeIsolated { onPan?(delta) }
        }

        override func mouseUp(with event: NSEvent) {
            if !moved, event.clickCount == 1 {
                let location = point(event)
                MainActor.assumeIsolated { onClick?(location) }
            }
            dragging = false
            lastPoint = nil
            window?.invalidateCursorRects(for: self)
        }

        override func scrollWheel(with event: NSEvent) {
            let location = point(event)
            let zoomModifier = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
            if event.hasPreciseScrollingDeltas && !zoomModifier {
                // 触控板双指滑动 = 平移
                MainActor.assumeIsolated { onPan?(CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)) }
            } else {
                // 鼠标滚轮或 ⌘/⌃ + 滚动 = 以光标为中心缩放
                let step = event.hasPreciseScrollingDeltas ? 0.012 : 0.09
                let factor = exp(Double(event.scrollingDeltaY) * step)
                MainActor.assumeIsolated { onZoom?(factor, location) }
            }
        }

        override func magnify(with event: NSEvent) {
            let factor = 1 + Double(event.magnification)
            let location = point(event)
            MainActor.assumeIsolated { onZoom?(factor, location) }
        }

        override func smartMagnify(with event: NSEvent) {
            MainActor.assumeIsolated { onDoubleClick?() }
        }

        override func keyDown(with event: NSEvent) {
            let anchor = CGPoint(x: bounds.midX, y: bounds.midY)
            switch event.charactersIgnoringModifiers {
            case "+", "=": MainActor.assumeIsolated { onZoom?(1.25, anchor) }
            case "-", "_": MainActor.assumeIsolated { onZoom?(1 / 1.25, anchor) }
            case "0": MainActor.assumeIsolated { onDoubleClick?() }
            default:
                if event.keyCode == 53 { MainActor.assumeIsolated { onClose?() } } else { super.keyDown(with: event) }
            }
        }
    }
}
