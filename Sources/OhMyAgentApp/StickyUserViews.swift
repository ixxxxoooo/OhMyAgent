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
                .padding(.bottom, 14)
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

/// 吸顶卡:最多两行,悬停出现放大图标,双击放大编辑。
struct StickyUserCard: View {
    let entry: TimelineEntry
    @Environment(\.stickyUser) private var sticky
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: entry.text.isEmpty ? String(localized: "(仅图片)") : entry.text)
                .font(OMFonts.reading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !entry.attachments.isEmpty {
                Label("\(entry.attachments.count)", om: "image").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            }
            Button { sticky?.editing = entry } label: {
                Image.om("maximize-2", size: 12).foregroundStyle(OMColors.secondaryText).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("放大编辑(双击)")
            .accessibilityLabel("放大编辑")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .omSolidCard()
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { sticky?.editing = entry }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "你:\(entry.text)"))
        .accessibilityHint(String(localized: "双击放大编辑"))
    }
}

/// 编辑并重新发送:放大的编辑窗,可切换模型。
struct UserMessageEditor: View {
    let model: SessionModel
    let entry: TimelineEntry
    let onClose: () -> Void
    @State private var text: String
    @State private var modelPickerShown = false

    init(model: SessionModel, entry: TimelineEntry, onClose: @escaping () -> Void) {
        self.model = model
        self.entry = entry
        self.onClose = onClose
        _text = State(initialValue: entry.text)
    }

    private var canResend: Bool {
        !model.isRunning && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !entry.attachments.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑并重新发送").font(OMFonts.title)
            TextEditor(text: $text)
                .font(OMFonts.reading)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 180)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(OMColors.hairline))
            if !entry.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(entry.attachments) { AttachmentThumbnail(attachment: $0, size: 56) } }
                }
            }
            Text(model.isRunning ? "回合进行中,结束后才能重新发送。" : "将作为新消息发送,原消息与回复会保留。")
                .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            HStack {
                modelButton
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Button("重新发送") {
                    let images = entry.attachments
                    let prompt = text
                    onClose()
                    model.send(prompt, images: images)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canResend)
            }
        }
        .padding(16)
        .frame(width: 560)
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
                .popover(isPresented: $modelPickerShown, arrowEdge: .bottom) {
                    ModelPickerList(sections: [ModelPickerSection(id: "m", title: nil, rows: rows)], searchable: rows.count > 8) { value in
                        modelPickerShown = false
                        model.setConfigOption(option.id, value: value)
                    }
                }
            }
        }
    }
}
