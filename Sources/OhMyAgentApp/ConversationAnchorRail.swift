// @author ixxxxoooo
// 对话锚点:会话流左侧边缘的迷你导航条。每条用户提问对应一根短横线,当前所在提问高亮;
// 光标划过时刻度按距离阶梯放大(Dock 式),并在右侧弹出被悬停那一条提问的预览卡片,点击跳转(对标 Cursor Composer / kuku)。
// 纯逻辑(文本拆分、阶梯尺寸、抽样、卡片对齐)在 `ConversationAnchorLogic.swift`。

import ChatKit
import DesignSystem
import SwiftUI

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
            let parts = AnchorText.split(entry.displayText)
            result.append(ConversationAnchor(
                id: entry.id, index: index, number: result.count + 1,
                title: parts.title.isEmpty ? String(localized: "(图片)") : parts.title, body: parts.body
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
    /// 点击某条提问的跳转动作(稳定的引用载体,使本视图入参恒定、可被 SwiftUI 跳过重算)
    let jump: AnchorJumpAction

    @State private var cache = AnchorCache()
    /// 光标正悬停的提问
    @State private var hoveredID: UUID?
    /// 用户刚点选的提问:视口贴底时(最后几条提问无法滚到顶部)据此高亮,滚离底部后失效
    @State private var picked: UUID?

    var body: some View {
        let anchors = cache.anchors(for: model.timeline)
        if anchors.count >= 2 {
            let current = currentAnchor(in: anchors)
            GeometryReader { proxy in
                ticks(anchors: anchors, current: current, available: proxy.size.height - 48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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

    /// 刻度列:提问过多时抽样(始终保留当前项);行与行紧挨,光标不会落进死区。
    private func ticks(anchors: [ConversationAnchor], current: UUID?, available: CGFloat) -> some View {
        let shown = AnchorRailMetrics.sample(anchors, current: current, available: available)
        let hoveredIndex = shown.firstIndex { $0.id == hoveredID }
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { offset, anchor in
                tick(anchor, offset: offset, count: shown.count, total: anchors.count,
                     isCurrent: anchor.id == current, hoveredIndex: hoveredIndex)
            }
        }
        .animation(omShouldReduceMotion() ? nil : .easeOut(duration: 0.14), value: hoveredID)
    }

    /// 单根刻度:阶梯放大 + 悬停预览。
    private func tick(_ anchor: ConversationAnchor, offset: Int, count: Int, total: Int, isCurrent: Bool, hoveredIndex: Int?) -> some View {
        let look = AnchorRailMetrics.indicator(distance: hoveredIndex.map { abs($0 - offset) }, isCurrent: isCurrent)
        return Button { picked = anchor.id; jump(anchor.id) } label: {
            RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous)
                .fill(isCurrent ? OMColors.accent : OMColors.secondaryText)
                .frame(width: look.width, height: look.height)
                .opacity(look.opacity)
                .frame(width: 30, height: AnchorRailMetrics.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "跳到第 \(anchor.number) 条提问"))
        .onHover { inside in
            if inside { hoveredID = anchor.id } else if hoveredID == anchor.id { hoveredID = nil }
        }
        .overlay(alignment: AnchorRailMetrics.popoverAlignment(index: offset, count: count)) {
            if hoveredID == anchor.id {
                preview(anchor, total: total)
                    .offset(x: 34)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .zIndex(hoveredID == anchor.id ? 1 : 0)
    }

    /// 悬停预览卡片:第 N / 共 M 次、首行标题、正文缩略。不接收鼠标事件,光标斜着划过也不会闪退。
    private func preview(_ anchor: ConversationAnchor, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "第 \(anchor.number) / \(total) 次提问"))
                .font(OMFonts.caption)
                .foregroundStyle(OMColors.tertiaryText)
            Text(verbatim: anchor.title)
                .font(OMFonts.body.weight(.medium))
                .foregroundStyle(OMColors.primaryText)
                .lineLimit(2)
            if !anchor.body.isEmpty {
                Text(verbatim: anchor.body)
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .lineLimit(3)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .omGlassCard()
    }
}
