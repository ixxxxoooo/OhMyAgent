// @author ixxxxoooo
// 对话锚点:会话流左侧边缘的迷你导航条。每条用户提问对应一根短横线,当前所在提问高亮;
// 鼠标移上去在右侧展开提问列表,点击跳转到对应提问(对标主流对话产品的「大纲/锚点」)。

import ChatKit
import DesignSystem
import SwiftUI

/// 一个对话锚点(对应一条用户提问)。
struct ConversationAnchor: Identifiable, Equatable {
    let id: UUID
    /// 在时间线条目数组里的下标
    let index: Int
    /// 第几条提问(从 1 起)
    let number: Int
    /// 提问首行(截断)
    let title: String
}

/// 锚点缓存:只在时间线结构变化时重算(流式文本追加不触发)。
@MainActor
private final class AnchorCache {
    var structureRevision = -1
    var count = -1
    var anchors: [ConversationAnchor] = []

    /// 取锚点列表。
    /// - Parameter store: 时间线
    func anchors(for store: TimelineStore) -> [ConversationAnchor] {
        if store.structureRevision == structureRevision, store.entries.count == count { return anchors }
        var result: [ConversationAnchor] = []
        for (index, entry) in store.entries.enumerated() where entry.kind == .user && !entry.isSteered {
            let firstLine = entry.displayText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let title = firstLine.trimmingCharacters(in: .whitespaces)
            result.append(ConversationAnchor(
                id: entry.id, index: index, number: result.count + 1,
                title: title.isEmpty ? String(localized: "(图片)") : String(title.prefix(80))
            ))
        }
        anchors = result
        structureRevision = store.structureRevision
        count = store.entries.count
        return result
    }
}

/// 对话锚点导航条。
struct ConversationAnchorRail: View {
    let model: SessionModel
    let sticky: StickyUserState
    /// 点击某条提问
    let onSelect: (UUID) -> Void

    @State private var cache = AnchorCache()
    @State private var hovering = false
    /// 用户刚点选的提问:视口贴底时(最后几条提问无法滚到顶部)据此高亮,滚离底部后失效
    @State private var picked: UUID?

    /// 单根刻度占用的最小高度
    private static let minRow: CGFloat = 7
    private static let maxRow: CGFloat = 14

    var body: some View {
        let anchors = cache.anchors(for: model.timeline)
        if anchors.count >= 2 {
            let current = currentAnchor(in: anchors)
            GeometryReader { proxy in
                HStack(spacing: 6) {
                    ticks(anchors: anchors, current: current, available: proxy.size.height - 48)
                    if hovering {
                        listCard(anchors: anchors, current: current, maxHeight: proxy.size.height - 48)
                            .transition(.opacity)
                    }
                }
                // 悬停区只包住刻度(与展开后的列表),不含周围空白:鼠标真正移到刻度上才唤醒
                .onHover { hovering = $0 }
                .animation(omShouldReduceMotion() ? nil : .easeOut(duration: 0.12), value: hovering)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .allowsHitTesting(true)
            }
            .padding(.leading, 6)
        }
    }

    /// 当前所在提问:最靠上的可见条目之前(含)最近的一条;视口贴底时取点选项或最后一条;没有可见信息时取最后一条。
    private func currentAnchor(in anchors: [ConversationAnchor]) -> UUID? {
        guard let top = sticky.topIndex else { return anchors.last?.id }
        if sticky.atBottom {
            // 贴底:点选过且仍在可见区之后/内的取点选项,否则取最后一条
            if let picked, let hit = anchors.first(where: { $0.id == picked }), hit.index >= top { return picked }
            return anchors.last?.id
        }
        return (anchors.last { $0.index <= top } ?? anchors.first)?.id
    }

    /// 刻度列:提问过多时按步长抽样(始终保留当前项)。
    private func ticks(anchors: [ConversationAnchor], current: UUID?, available: CGFloat) -> some View {
        let capacity = max(2, Int(max(available, 0) / Self.minRow))
        let stride = max(1, Int((Double(anchors.count) / Double(capacity)).rounded(.up)))
        let shown = anchors.enumerated().filter { $0.offset % stride == 0 || $0.element.id == current }.map(\.element)
        let row = min(Self.maxRow, max(Self.minRow, available / CGFloat(max(shown.count, 1))))
        return VStack(spacing: 0) {
            ForEach(shown) { anchor in
                let isCurrent = anchor.id == current
                Button { picked = anchor.id; onSelect(anchor.id) } label: {
                    RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous)
                        .fill(isCurrent ? OMColors.accent : OMColors.tertiaryText.opacity(hovering ? 0.8 : 0.5))
                        .frame(width: isCurrent ? 16 : 10, height: 2)
                        .frame(width: 20, height: row, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "跳到第 \(anchor.number) 条提问"))
            }
        }
    }

    /// 悬停展开的提问列表。
    private func listCard(anchors: [ConversationAnchor], current: UUID?, maxHeight: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(anchors) { anchor in
                        let isCurrent = anchor.id == current
                        Button { picked = anchor.id; onSelect(anchor.id) } label: {
                            HStack(spacing: 8) {
                                Text(verbatim: "\(anchor.number)")
                                    .font(OMFonts.caption)
                                    .foregroundStyle(isCurrent ? OMColors.accentText : OMColors.tertiaryText)
                                    .frame(minWidth: 16, alignment: .trailing)
                                Text(verbatim: anchor.title)
                                    .font(OMFonts.small)
                                    .foregroundStyle(isCurrent ? OMColors.primaryText : OMColors.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(isCurrent ? OMColors.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(anchor.id)
                    }
                }
                .padding(6)
            }
            .onAppear { if let current { reader.scrollTo(current, anchor: .center) } }
        }
        .frame(width: 260)
        .frame(maxHeight: min(max(maxHeight, 80), 360))
        .fixedSize(horizontal: false, vertical: true)
        .omGlassCard()
    }
}
