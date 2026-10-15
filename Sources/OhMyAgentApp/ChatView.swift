// @author ygw
// 对话区:时间线(锚定底部、流式时自动跟随)+ 浮动输入区。

import ChatKit
import DesignSystem
import SwiftUI

/// 对话视图。
struct ChatView: View {
    let model: SessionModel
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isPinnedToBottom = true

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
                if case .failed(let message) = model.phase {
                    ConnectionFailureCard(message: message) { model.reconnect() }
                }
                ComposerView(model: model)
            }
            .frame(maxWidth: OMMetrics.timelineMaxWidth)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if model.timeline.entries.isEmpty {
                    EmptyStateView(model: model)
                        .padding(.top, 80)
                }
                ForEach(model.timeline.entries) { entry in
                    TimelineEntryView(entry: entry)
                }
                Color.clear.frame(height: 24).id("bottom")
            }
            .frame(maxWidth: OMMetrics.timelineMaxWidth)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
        } action: { _, atBottom in
            isPinnedToBottom = atBottom
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
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
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
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(OMColors.warning)
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
