// @author ixxxxoooo
// 吸顶用户消息(对标 Cursor):向上滚动时,当前回合的用户消息固定在会话流顶部;
// 下一条用户消息上来时把前一条顶出;双击用户消息放大为编辑窗,可切换模型并重新发送。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 会话流滚动区的命名坐标空间。
let chatScrollSpace = "chatScroll"

/// 吸顶状态:最靠上的可见条目、各用户消息行的位置与解析出的吸顶目标。
/// 只在目标变化时写 `target`,避免滚动中频繁刷新依赖它的视图。
@MainActor
@Observable
final class StickyUserState {
    /// 当前可见的最靠上条目的下标
    private(set) var topIndex: Int?
    /// 各用户消息行在滚动视口中的顶边 Y
    private(set) var userMinY: [UUID: CGFloat] = [:]
    /// 吸顶卡(仅卡片本体)高度
    var cardHeight: CGFloat = 0
    /// 当前吸顶目标
    private(set) var target: StickyUser.Target?
    /// 正在「编辑并重新发送」的用户消息(非 nil 时弹出编辑窗)
    var editing: TimelineEntry?
    /// 编辑是从吸顶卡发起的:编辑卡就悬浮在顶部、向下展开,不跳回消息原来的滚动位置
    private(set) var editorPinned = false
    /// 编辑中的草稿:编辑卡在「悬浮」与「原位」之间切换时不丢已输入的内容
    var editDraft: String?
    /// 用户刚展开/折叠了某一行:暂停「贴底自动跟随」,避免内容增高把视口拽走(滚回底部后自动恢复)
    @ObservationIgnored var followSuspended = false
    @ObservationIgnored private(set) weak var model: SessionModel?

    /// 绑定会话模型。
    func bind(_ model: SessionModel) { self.model = model }

    /// 开始编辑一条用户消息。
    /// - Parameters:
    ///   - entry: 要编辑的消息
    ///   - pinned: 是否从吸顶卡发起(true 时编辑卡悬浮在顶部,不回到原位置)
    func beginEditing(_ entry: TimelineEntry, pinned: Bool) {
        editDraft = nil
        editorPinned = pinned
        editing = entry
    }

    /// 结束编辑(取消或发送)。
    func finishEditing() {
        omWithAnimation {
            editing = nil
            editorPinned = false
            editDraft = nil
        }
    }

    /// 编辑卡是否应显示在顶部悬浮层(而不是消息原位)。
    func isEditorFloating(for id: UUID) -> Bool { editing?.id == id && editorPinned }

    /// 可见条目集合变化:取其中最靠上的一条。
    /// - Parameter ids: 可见条目 ID(分组的 ID 等于其首个条目的 ID)
    func updateVisible(_ ids: [UUID]) {
        guard let entries = model?.timeline.entries else { return }
        let visible = Set(ids)
        let index = entries.firstIndex { visible.contains($0.id) }
        if index != topIndex { topIndex = index }
        recompute()
    }

    /// 用户消息行位置变化。
    func report(_ id: UUID, minY: CGFloat) {
        guard userMinY[id] != minY else { return }
        userMinY[id] = minY
        recompute()
    }

    /// 用户消息行离开渲染范围。
    func forget(_ id: UUID) {
        guard userMinY.removeValue(forKey: id) != nil else { return }
        recompute()
    }

    private func recompute() {
        guard let entries = model?.timeline.entries else { return }
        let next = StickyUser.resolve(entries: entries, topIndex: topIndex, userMinY: userMinY, pushZone: cardHeight + 24)
        if next != target { target = next }
    }
}

extension EnvironmentValues {
    /// 吸顶状态(用户消息行据此上报位置、被吸顶时隐藏自身)
    @Entry var stickyUser: StickyUserState?
}

/// 叠在会话流顶部的吸顶层。
struct StickyUserOverlay: View {
    let model: SessionModel
    let state: StickyUserState
    let maxWidth: CGFloat

    var body: some View {
        if let editing = state.editing, state.editorPinned {
            // 从吸顶卡进入编辑:编辑卡就在当前悬浮位置向下展开,覆盖在会话流之上
            UserMessageEditor(model: model, entry: editing, maxWidth: .infinity) { state.finishEditing() }
                .id(editing.id)
                .frame(maxWidth: maxWidth)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
                .background(alignment: .top) {
                    LinearGradient(colors: [OMColors.surface, OMColors.surface.opacity(0.92), OMColors.surface.opacity(0)], startPoint: .top, endPoint: .bottom) // ui-lint:allow 仅作遮罩/淡出,非装饰
                        .allowsHitTesting(false)
                }
                .transition(.opacity)
        } else if let target = state.target, target.stickyID != state.editing?.id,
                  let entry = model.timeline.entries.first(where: { $0.id == target.stickyID }) {
            // 正在原位编辑的那条不再吸顶,避免与行内编辑卡重复
            let push = StickyUser.pushOffset(nextMinY: target.nextID.flatMap { state.userMinY[$0] }, cardHeight: state.cardHeight)
            StickyUserCard(entry: entry)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.cardHeight = $0 }
                .frame(maxWidth: maxWidth)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
                .background(alignment: .top) {
                    // 卡片下缘渐隐进内容,和会话流顶部淡出衔接
                    LinearGradient(colors: [OMColors.surface, OMColors.surface.opacity(0.92), OMColors.surface.opacity(0)], startPoint: .top, endPoint: .bottom) // ui-lint:allow 仅作遮罩/淡出,非装饰
                        .allowsHitTesting(false)
                }
                .offset(y: push)
                .transition(.opacity)
        }
    }
}

/// 吸顶卡(图4 风格,沿用底部输入框的玻璃卡片):附件缩略图 + 最多三行正文,
/// 悬停出现「编辑」图标,双击放大编辑。
struct StickyUserCard: View {
    let entry: TimelineEntry
    @Environment(\.stickyUser) private var sticky
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.attachments.prefix(4)) { AttachmentThumbnail(attachment: $0, size: 30) }
                    if entry.attachments.count > 4 {
                        Text(verbatim: "+\(entry.attachments.count - 4)").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                    }
                }
            }
            if !entry.text.isEmpty {
                Text(verbatim: entry.text)
                    .font(OMFonts.reading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omGlass(in: RoundedRectangle(cornerRadius: OMRadius.modal, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Button { sticky?.beginEditing(entry, pinned: true) } label: {
                Image.om("square-pen", size: 12).foregroundStyle(OMColors.secondaryText).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .padding(8)
            .help("放大编辑(双击)")
            .accessibilityLabel("放大编辑")
        }
        .contentShape(RoundedRectangle(cornerRadius: OMRadius.modal, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { sticky?.beginEditing(entry, pinned: true) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "你:\(entry.text)"))
        .accessibilityHint(String(localized: "双击放大编辑"))
    }
}

/// 编辑并重新发送(图3 风格):在原消息位置就地向下展开的输入卡片(不再是悬浮窗),
/// 版式与底部输入框一致——上方附件与文本,底部左侧模型选择,右侧取消与圆形发送按钮。
struct UserMessageEditor: View {
    let model: SessionModel
    let entry: TimelineEntry
    let maxWidth: CGFloat
    let onClose: () -> Void
    @State private var text: String
    @State private var modelPickerShown = false
    /// 文本区高度:随内容增长(最小一行,超过 `maxEditorHeight` 才滚动)
    @State private var editorHeight: CGFloat = 34
    /// 编辑区最大高度
    private let maxEditorHeight: CGFloat = 320
    @State private var controller = ComposerController()

    init(model: SessionModel, entry: TimelineEntry, maxWidth: CGFloat, onClose: @escaping () -> Void) {
        self.model = model
        self.entry = entry
        self.maxWidth = maxWidth
        self.onClose = onClose
        _text = State(initialValue: entry.text)
    }

    /// 作为新消息重新发送(原消息与回复保留)。
    private func resend() {
        guard canResend else { return }
        let images = entry.attachments
        let prompt = text
        onClose()
        model.send(prompt, images: images)
    }

    private var canResend: Bool {
        !model.isRunning && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !entry.attachments.isEmpty)
    }

    var body: some View {
        // 就地展开:占据原消息行的位置,随内容向下延展,会话流内容自然被推开
        card
            .omDismissOnClickOutside(perform: onClose)
            .transition(.opacity)
            .onExitCommand(perform: onClose)
            .onAppear { controller.focus() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !entry.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(entry.attachments) { AttachmentThumbnail(attachment: $0, size: 56) } }
                }
            }
            // 与底部输入框同一套文本视图:高度随内容自适应,不再固定
            ComposerTextView(
                text: $text, height: $editorHeight, placeholder: "", maxHeight: maxEditorHeight,
                onSubmit: resend, onEscape: onClose, controller: controller
            )
            .frame(height: editorHeight)
            if model.isRunning {
                Text("回合进行中,结束后才能重新发送。").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            }
            HStack(spacing: 6) {
                modelButton
                Spacer(minLength: 8)
                Button("取消", action: onClose)
                    .buttonStyle(.plain)
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .keyboardShortcut(.cancelAction)
                if ThemeRuntime.style.primaryButton == .ink || !ThemeRuntime.style.allowsGlass {
                    ComposerPaperSendButton(
                        isRunning: false,
                        hasContent: canResend,
                        help: String(localized: "重新发送 (⌘Return)"),
                        onSend: resend
                    )
                    .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Button(action: resend) {
                        Image.om("arrow.up", size: 12, weight: .bold).frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canResend)
                    .help("重新发送 (⌘Return)")
                    .accessibilityLabel("重新发送")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .omGlass(in: RoundedRectangle(cornerRadius: OMRadius.modal, style: .continuous))
    }

    /// 模型切换按钮(没有可切换的模型时不显示)。
    @ViewBuilder
    private var modelButton: some View {
        if let option = model.option(category: "model") {
            let rows = OptionMenu.modelPickerRows(model: model, option: option)
            if !rows.isEmpty {
                let shown = rows.first { $0.isSelected } ?? rows[0]
                Button { modelPickerShown.toggle() } label: {
                    HStack(spacing: 6) {
                        if let brand = shown.brand { BrandIconView(brand, size: 13) }
                        Text(verbatim: shown.name).font(OMFonts.small).lineLimit(1)
                        Image.om("chevron-down", size: 10).foregroundStyle(OMColors.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("切换模型")
                .accessibilityLabel("切换模型")
                .omPicker(isPresented: $modelPickerShown, items: rows, selectedID: shown.id, placeholder: String(localized: "搜索模型"),
                          placement: .below, width: 300, row: { ModelPickRowContent(row: $0) }, onSelect: { row in
                    model.setConfigOption(option.id, value: row.id)
                })
            }
        }
    }
}

/// 记录宿主卡片 NSView 的容器。
@MainActor
final class OutsideClickAnchorBox {
    weak var view: NSView?
}

/// 放置在卡片背后以获取卡片在窗口中的几何边界。
struct OutsideClickAnchor: NSViewRepresentable {
    let box: OutsideClickAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

/// 外部点击(空白处)取消编辑的协调器。
@MainActor
final class OutsideClickDismissCoordinator {
    let box = OutsideClickAnchorBox()
    private var monitor: Any?
    /// 是否在等待当前点击手势的抬起事件,将其一并消费防止落入下层视图导致闪烁
    private var pendingMouseUp = false
    var onDismiss: (() -> Void)?

    /// 安装全局鼠标点击监听(仅在编辑展示期间生效)。
    func install() {
        guard monitor == nil else { return }
        pendingMouseUp = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }
    }

    /// 移除鼠标监听。
    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        pendingMouseUp = false
    }

    /// 命中检测与事件处理。
    func handle(_ event: NSEvent) -> Bool {
        // 如果正在等待对应的 mouseUp:在抬起瞬间触发关闭,并完整吞掉该抬起事件
        if pendingMouseUp {
            if event.type == .leftMouseUp {
                remove()
                onDismiss?()
                return true
            }
            return false
        }

        // 如果当前有全局选择浮层(如模型切换面板)或右键菜单展示,外部点击交由其自身处理
        if PickerPanelController.shared.isPresented { return false }
        if OMContextMenuCenter.shared.isPresented { return false }

        guard let cardView = box.view, let cardWindow = cardView.window else { return false }
        // 仅处理发生在当前窗口内的鼠标点击
        guard event.window === cardWindow else { return false }

        let locationInView = cardView.convert(event.locationInWindow, from: nil)
        if cardView.bounds.contains(locationInView) {
            // 点击在编辑卡片内部(输入框、按钮、附件等),放行事件
            return false
        }

        // 点击在编辑窗口之外的空白处:
        if event.type == .leftMouseDown {
            pendingMouseUp = true
            // 让当前窗口文本第一响应者平滑失焦,避免光标与文字选区在退出时撕裂闪烁
            cardWindow.makeFirstResponder(nil)
            return true
        } else if event.type == .rightMouseDown {
            remove()
            cardWindow.makeFirstResponder(nil)
            onDismiss?()
            return true
        }

        return false
    }
}

/// 点击外部空白处取消编辑的 ViewModifier。
struct OutsideClickDismissModifier: ViewModifier {
    let onDismiss: () -> Void
    @State private var coordinator = OutsideClickDismissCoordinator()

    func body(content: Content) -> some View {
        content
            .background(OutsideClickAnchor(box: coordinator.box))
            .onAppear {
                coordinator.onDismiss = onDismiss
                coordinator.install()
            }
            .onDisappear {
                coordinator.remove()
            }
    }
}

extension View {
    /// 当点击卡片外部(空白处)时自动取消。
    func omDismissOnClickOutside(perform onDismiss: @escaping () -> Void) -> some View {
        modifier(OutsideClickDismissModifier(onDismiss: onDismiss))
    }
}

