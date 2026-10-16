// @author ygw
// 对话区:时间线(锚定底部、流式时自动跟随)+ 浮动输入区。

import IconKit
import ChatKit
import DesignSystem
import SwiftUI
import WorkbenchKit

/// 对话视图。
struct ChatView: View {
    let model: SessionModel
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isPinnedToBottom = true
    @State private var scrollPhase: ScrollPhase = .idle
    /// 聊天内容宽度档位(设置 → 外观)
    @AppStorage(ClientPrefs.Key.chatWidth) private var chatWidth = ChatWidth.standard.rawValue

    private var contentMaxWidth: CGFloat { (ChatWidth(rawValue: chatWidth) ?? .standard).points }

    var body: some View {
        ZStack {
            OMColors.surface.ignoresSafeArea()
            timeline
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                ForEach(model.pendingPermissions) { prompt in
                    PermissionCard(prompt: prompt) { optionId in
                        model.resolve(prompt, optionId: optionId)
                    }
                }
                // 提问按队列逐个呈现(先到先答),其余以「还有 N 个待回答」提示
                if let prompt = model.pendingElicitations.first {
                    ElicitationCard(prompt: prompt, queued: model.pendingElicitations.count - 1) { model.dismiss(prompt) }
                        .id(prompt.id)
                }
                if case .failed(let message) = model.phase {
                    ConnectionFailureCard(message: message) { model.reconnect() }
                }
                PlanDock(model: model)
                SubagentActivityStrip(model: model, workbench: AppEnvironment.shared.workbench)
                GoalChip(model: model)
                FollowUpQueueView(model: model)
                ComposerView(model: model)
                ComposerFooter(model: model)
            }
            .frame(maxWidth: contentMaxWidth)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .task(id: ObjectIdentifier(model)) { ChatBindings.bind(model) }
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppearanceModel.shared.isCompact ? 7 : 14) {
                if model.timeline.entries.isEmpty {
                    EmptyStateView(model: model)
                        .padding(.top, 80)
                }
                ForEach(TimelineGrouping.group(model.timeline.entries)) { item in
                    TimelineItemView(item: item)
                }
                WorkingIndicatorView(model: model)
                Color.clear.frame(height: 24).id("bottom")
            }
            .frame(maxWidth: contentMaxWidth)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .onScrollPhaseChange { _, phase in scrollPhase = phase }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
        } action: { _, atBottom in
            // 内容增高(工具详情异步展开、Diff 计算完成)会让“是否在底部”暂时为假;
            // 只有用户主动滚动(非空闲阶段)离开底部才取消跟随。
            if atBottom { isPinnedToBottom = true } else if scrollPhase != .idle { isPinnedToBottom = false }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
            if isPinnedToBottom { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: model.timeline.revision) {
            if isPinnedToBottom { position.scrollTo(edge: .bottom) }
        }
    }
}

/// 空状态。
struct EmptyStateView: View {
    let model: SessionModel

    var body: some View {
        VStack(spacing: 10) {
            Image.om("sparkles", size: 30, weight: .light)
                .foregroundStyle(OMColors.accent)
            Text("有什么可以帮你?")
                .font(OMFonts.title)
            Text(model.workspace.abbreviatingHome)
                .font(OMFonts.small)
                .foregroundStyle(OMColors.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// 连接失败提示卡。
struct ConnectionFailureCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image.om("exclamationmark.triangle.fill").foregroundStyle(OMColors.warning)
            Text(message)
                .font(OMFonts.small)
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试", action: retry)
        }
        .padding(12)
        .omSolidCard()
    }
}
