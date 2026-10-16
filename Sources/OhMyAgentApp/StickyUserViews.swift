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
    /// 用户刚展开/折叠了某一行:暂停「贴底自动跟随」,避免内容增高把视口拽走(滚回底部后自动恢复)
    @ObservationIgnored var followSuspended = false
    @ObservationIgnored private weak var model: SessionModel?

    /// 绑定会话模型。
    func bind(_ model: SessionModel) { self.model = model }

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
        if let target = state.target, let entry = model.timeline.entries.first(where: { $0.id == target.stickyID }) {
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
                    LinearGradient(colors: [OMColors.surface, OMColors.surface.opacity(0.92), OMColors.surface.opacity(0)], startPoint: .top, endPoint: .bottom)
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
        .omGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Button { sticky?.editing = entry } label: {
                Image.om("square-pen", size: 12).foregroundStyle(OMColors.secondaryText).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .padding(8)
            .help("放大编辑(双击)")
            .accessibilityLabel("放大编辑")
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { sticky?.editing = entry }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "你:\(entry.text)"))
        .accessibilityHint(String(localized: "双击放大编辑"))
    }
}

/// 编辑并重新发送(图3 风格):在会话流上方就地展开的大输入卡片,
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
        ZStack(alignment: .top) {
            // 点击空白处关闭;轻微压暗,突出编辑卡片
            Color.black.opacity(0.08)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
            card
                .frame(maxWidth: maxWidth)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
        }
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .omGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
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
