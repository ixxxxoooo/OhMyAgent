// @author ixxxxoooo
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
    /// 吸顶用户消息的状态(位置上报、目标解析)
    @State private var sticky = StickyUserState()
    /// 分组结果缓存(输入区等无关状态变化时不重复分组)
    @State private var itemsCache = TimelineItemsCache()
    /// 上下文用量面板是否展开
    @State private var usageOpen = ProcessInfo.processInfo.environment["OMA_USAGE_PANEL"] != nil   // 调试钩子:启动即展开
    /// 聊天内容宽度档位(设置 → 主题)
    @AppStorage(ClientPrefs.Key.chatWidth) private var chatWidth = ChatWidth.standard.rawValue

    @AppStorage(ClientPrefs.Key.chatWidthCustom) private var chatWidthCustom = ChatWidth.customDefault

    private var contentMaxWidth: CGFloat { ChatWidth.resolve(raw: chatWidth, custom: chatWidthCustom) }

    /// 新会话(时间线为空):输入区居中显示,对齐 kuku/Cursor 的新对话首屏。
    private var isEmptySession: Bool { model.timeline.entries.isEmpty }

    var body: some View {
        ZStack {
            OMColors.surface.ignoresSafeArea()
            // 输入区在两种布局下处于同一结构位置,发送首条消息时不会被重建(保留焦点与草稿)
            VStack(spacing: 0) {
                if isEmptySession {
                    Spacer(minLength: 0)
                    EmptyStateView(model: model)
                        .padding(.bottom, 28)
                } else {
                    timeline
                }
                composerStack
                if isEmptySession {
                    Spacer(minLength: 0)
                    // 视觉重心略微上移(对齐 kuku 的 pb-20)
                    Color.clear.frame(height: 72)
                }
            }
        }
        .task(id: ObjectIdentifier(model)) { ChatBindings.bind(model) }
        .environment(\.stickyUser, sticky)
        .sheet(item: $sticky.editing) { entry in
            UserMessageEditor(model: model, entry: entry) { sticky.editing = nil }
        }
        .onAppear { sticky.bind(model) }
    }

    /// 底部(新会话时居中)的输入区栈:权限/提问/连接失败卡、计划与目标、用量面板、输入框与页脚。
    private var composerStack: some View {
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
            GoalChip(model: model)
            if usageOpen {
                ContextUsagePanel(model: model) { omWithAnimation { usageOpen = false } }
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            ComposerDockView(model: model, workbench: AppEnvironment.shared.workbench)
            ComposerView(model: model)
            ComposerFooter(model: model, usageOpen: $usageOpen)
        }
        .frame(maxWidth: contentMaxWidth)
        .padding(.horizontal, 16)
        .padding(.bottom, isEmptySession ? 0 : 12)
        .frame(maxWidth: .infinity)
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppearanceModel.shared.isCompact ? 7 : 14) {
                ForEach(itemsCache.items(for: model.timeline)) { item in
                    // Equatable:结构不变时不因父视图重新求值而重建行(行内容由条目自身的可观察状态驱动)
                    TimelineItemView(item: item).equatable()
                }
                WorkingIndicatorView(model: model)
                Color.clear.frame(height: 36).id("bottom")
            }
            .scrollTargetLayout()
            .frame(maxWidth: contentMaxWidth)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity)
        }
        .coordinateSpace(.named(chatScrollSpace))
        .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.01) { ids in sticky.updateVisible(ids) }
        .mask(TimelineEdgeFade())
        .overlay(alignment: .top) { StickyUserOverlay(model: model, state: sticky, maxWidth: contentMaxWidth) }
        .clipped()
        .scrollPosition($position)
        .onScrollPhaseChange { _, phase in scrollPhase = phase }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
        } action: { _, atBottom in
            // 内容增高(工具详情异步展开、Diff 计算完成)会让“是否在底部”暂时为假;
            // 只有用户主动滚动(非空闲阶段)离开底部才取消跟随。
            if atBottom {
                isPinnedToBottom = true
                sticky.followSuspended = false
            } else if scrollPhase != .idle {
                isPinnedToBottom = false
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
            if isPinnedToBottom, !sticky.followSuspended { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: model.timeline.revision) {
            if isPinnedToBottom, !sticky.followSuspended { position.scrollTo(edge: .bottom) }
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
        .omGlassCard()
    }
}

/// 会话流上下边缘的淡入淡出遮罩:内容滚到边缘时渐隐,而不是被硬切。
struct TimelineEdgeFade: View {
    /// 顶部渐隐高度
    static let topHeight: CGFloat = 18
    /// 底部渐隐高度(略高,与输入区衔接)
    static let bottomHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Self.topHeight)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.bottomHeight)
        }
        .allowsHitTesting(false)
    }
}
