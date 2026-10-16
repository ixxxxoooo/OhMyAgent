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
    /// 跟随底部状态(纯逻辑,见 ChatKit.FollowState)
    @State private var follow = FollowState()
    @State private var scrollPhase: ScrollPhase = .idle
    /// 上下边缘是否还有被遮住的内容(没有时不做渐隐,避免末行文字被淡化、底部留出多余空白)
    @State private var fadeEdges = TimelineEdgeFade.Edges(top: false, bottom: false)
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
        .overlay {
            // 图3 风格:就地展开的编辑卡片(不再用系统 sheet)
            if let entry = sticky.editing {
                UserMessageEditor(model: model, entry: entry, maxWidth: contentMaxWidth) { sticky.editing = nil }
                    .id(entry.id)
            }
        }
        .animation(omShouldReduceMotion() ? nil : .easeOut(duration: 0.15), value: sticky.editing?.id)
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
                Color.clear.frame(height: 8).id("bottom")
            }
            .scrollTargetLayout()
            .frame(maxWidth: contentMaxWidth)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity)
        }
        .coordinateSpace(.named(chatScrollSpace))
        .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.01) { ids in sticky.updateVisible(ids) }
        .mask(TimelineEdgeFade(edges: fadeEdges))
        .overlay(alignment: .top) { StickyUserOverlay(model: model, state: sticky, maxWidth: contentMaxWidth) }
        .clipped()
        .scrollPosition($position)
        .onScrollPhaseChange { _, phase in scrollPhase = phase }
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(offsetY: geometry.contentOffset.y, contentHeight: geometry.contentSize.height, containerHeight: geometry.containerSize.height)
        } action: { _, metrics in
            // 内容增高(工具详情异步展开)不会放手;用户主动向上滚(或在滚动中离开底部)才放手
            follow.geometryChanged(
                offsetY: metrics.offsetY, contentHeight: metrics.contentHeight, containerHeight: metrics.containerHeight,
                userScrolling: scrollPhase != .idle, entryCount: model.timeline.entries.count
            )
            if follow.pinned { sticky.followSuspended = false }
        }
        .onScrollGeometryChange(for: TimelineEdgeFade.Edges.self) { geometry in
            TimelineEdgeFade.Edges(
                top: geometry.contentOffset.y > 2,
                bottom: geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 4
            )
        } action: { _, edges in
            omWithAnimation { fadeEdges = edges }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
            autoFollow()
        }
        .onChange(of: model.timeline.revision) { autoFollow() }
        .overlay(alignment: .bottom) { jumpButton }
    }

    /// 内容变化后:贴底且用户没在滚动时才自动滚到底;否则只累计「新消息」。
    private func autoFollow() {
        let shouldScroll = follow.contentChanged(entryCount: model.timeline.entries.count, userScrolling: scrollPhase != .idle)
        if shouldScroll, !sticky.followSuspended { position.scrollTo(edge: .bottom) }
    }

    /// 离开底部时的悬浮按钮:回到最新;有新内容时显示条数。
    @ViewBuilder
    private var jumpButton: some View {
        if follow.showsJumpButton {
            JumpToLatestButton(unseen: follow.unseen, hasActivity: follow.hasActivity || model.isRunning) {
                follow.jumpToLatest()
                sticky.followSuspended = false
                omWithAnimation { position.scrollTo(edge: .bottom) }
            }
            .padding(.bottom, 10)
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}

/// 滚动几何快照(Equatable,避免无关变化触发回调)。
private struct ScrollMetrics: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
}

/// 「回到最新」悬浮按钮:沿用输入区的玻璃卡片风格。
struct JumpToLatestButton: View {
    /// 离开底部后新增的条目数
    let unseen: Int
    /// 是否有内容在更新(运行中或有新增)
    let hasActivity: Bool
    let action: () -> Void

    private var label: String {
        if unseen > 0 { return String(localized: "\(unseen) 条新消息") }
        return hasActivity ? String(localized: "有新内容") : String(localized: "回到最新")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image.om("arrow-down", size: 11, weight: .bold)
                Text(label).font(OMFonts.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .omGlassCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help("回到最新消息")
    }
}

/// 空状态。
struct EmptyStateView: View {
    let model: SessionModel

    var body: some View {
        VStack(spacing: 10) {
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

    /// 哪些边缘需要渐隐(该方向还有被遮住的内容时才需要)。
    struct Edges: Equatable {
        var top: Bool
        var bottom: Bool
    }

    /// 当前需要渐隐的边缘
    let edges: Edges

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: edges.top ? Self.topHeight : 0)
            Rectangle().fill(OMColors.maskInk)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: edges.bottom ? Self.bottomHeight : 0)
        }
        .allowsHitTesting(false)
    }
}
