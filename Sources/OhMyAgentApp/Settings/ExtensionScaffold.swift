// @author ixxxxoooo
// 扩展类设置页(MCP / 技能 / 子 Agent / Hooks / 插件 / 记忆)的统一页面骨架:
// 页头(图标 + 标题 + 说明 + 右侧操作)、状态条、卡片列表容器与卡片组件。参考 Cursor 的设置页版式。

import ClaudeConfigKit
import DesignSystem
import IconKit
import SwiftUI

/// 扩展分区(深链与旧入口使用);每个分区对应一个独立的设置页。
enum ExtensionSection: String, CaseIterable, Identifiable {
    case mcp, skills, agents, hooks, plugins, memory
    var id: String { rawValue }

    /// 对应的设置页。
    var page: SettingsPage {
        switch self {
        case .mcp: return .mcp
        case .skills: return .skills
        case .agents: return .subagents
        case .hooks: return .hooks
        case .plugins: return .plugins
        case .memory: return .memory
        }
    }
}

/// 页头:图标瓦片 + 标题与一句话说明 + 右侧操作区。
struct ExtensionHeader<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image.om(icon, size: 18)
                .foregroundStyle(OMColors.accent)
                .frame(width: 38, height: 38)
                .background(OMColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(OMFonts.title)
                Text(verbatim: subtitle).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(2)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions }
        }
    }
}

/// 可滚动的卡片页:页头 + 状态条 + 内容(卡片列表)。内容限宽居中。
struct ExtensionPage<Actions: View, Content: View>: View {
    let center: ConfigCenter
    let icon: String
    let title: String
    let subtitle: String
    /// 对应 `snapshot.errors` 的区块名(读取失败时在页头下提示)
    var errorKey: String?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ExtensionHeader(icon: icon, title: title, subtitle: subtitle) { actions }
                ExtensionBanners(center: center, errorKey: errorKey)
                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(OMColors.surface)
    }
}

/// 页头固定、内容区撑满剩余高度的页面(内容自带滚动或分栏,如 Hooks / 插件 / 记忆)。
struct ExtensionFixedPage<Actions: View, Content: View>: View {
    let center: ConfigCenter
    let icon: String
    let title: String
    let subtitle: String
    var errorKey: String?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExtensionHeader(icon: icon, title: title, subtitle: subtitle) { actions }
                .padding(.horizontal, 28)
                .padding(.top, 22)
            ExtensionBanners(center: center, errorKey: errorKey).padding(.horizontal, 28)
            content
                .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OMColors.surface)
    }
}

/// 状态提示条:忙碌/成功/错误(圆角卡片样式)与区块读取失败。
struct ExtensionBanners: View {
    let center: ConfigCenter
    var errorKey: String?

    var body: some View {
        VStack(spacing: 8) {
            if let message = center.busyMessage {
                banner(icon: nil, text: message, tint: OMColors.secondaryText, showsProgress: true)
            }
            if let error = center.lastError {
                banner(icon: "xmark.octagon.fill", text: error, tint: .red, dismiss: { center.lastError = nil })
            } else if let notice = center.lastNotice {
                banner(icon: "checkmark.circle.fill", text: notice, tint: .green)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if center.lastNotice == notice { center.lastNotice = nil }
                    }
            }
            if let errorKey, let readError = center.snapshot.errors[errorKey] {
                banner(icon: "exclamationmark.triangle.fill", text: readError, tint: OMColors.warning)
            }
        }
    }

    private func banner(icon: String?, text: String, tint: Color, showsProgress: Bool = false, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if showsProgress { ProgressView().controlSize(.small) }
            if let icon { Image.om(icon, size: 13).foregroundStyle(tint) }
            Text(verbatim: text).font(OMFonts.small).textSelection(.enabled).lineLimit(4)
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) { Image.om("x", size: 11) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭错误提示")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 卡片列表中的分组小标题(例如「用户」「工作区」)。
struct ExtensionSectionLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title).font(OMFonts.small.weight(.semibold)).foregroundStyle(OMColors.secondaryText)
            Text("\(count)").font(OMFonts.caption.monospacedDigit()).foregroundStyle(OMColors.tertiaryText)
        }
        .padding(.top, 6)
        .padding(.leading, 2)
    }
}

/// 把一组行装进圆角卡片(行与行之间用细分隔线)。
struct ExtensionCardList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
    }
}

/// 卡片列表中的一行:图标瓦片 + 名称/标签/说明 + 右侧控件;悬停高亮,可点击。
struct ExtensionRow<Badges: View, Trailing: View, Detail: View>: View {
    let icon: String
    var tint: Color = OMColors.accent
    let title: String
    var subtitle: String?
    var monoSubtitle = false
    var dimmed = false
    var expanded = false
    var onTap: (() -> Void)?
    @ViewBuilder var badges: Badges
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var detail: Detail
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image.om(icon, size: 14)
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: title).font(OMFonts.body.weight(.medium)).lineLimit(1)
                        badges
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(monoSubtitle ? OMFonts.monoSmall : OMFonts.small)
                            .foregroundStyle(OMColors.secondaryText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .opacity(dimmed ? 0.55 : 1)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            if expanded {
                detail
                    .padding(.horizontal, 14).padding(.leading, 42).padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .background(hovering && onTap != nil ? Color.primary.opacity(0.03) : .clear)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}

extension ExtensionRow where Detail == EmptyView {
    /// 没有展开详情的行。
    init(icon: String, tint: Color = OMColors.accent, title: String, subtitle: String? = nil, monoSubtitle: Bool = false, dimmed: Bool = false,
         onTap: (() -> Void)? = nil, @ViewBuilder badges: () -> Badges, @ViewBuilder trailing: () -> Trailing) {
        self.init(icon: icon, tint: tint, title: title, subtitle: subtitle, monoSubtitle: monoSubtitle, dimmed: dimmed, expanded: false,
                  onTap: onTap, badges: badges, trailing: trailing, detail: { EmptyView() })
    }
}

/// 卡片行之间的分隔线(缩进到文字起点)。
struct ExtensionRowDivider: View {
    var body: some View { Divider().padding(.leading, 56) }
}

/// 搜索框(圆角浅底)。
struct ExtensionSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image.om("search", size: 12).foregroundStyle(OMColors.tertiaryText)
            TextField(text: $text) { Text(verbatim: omLocalized(placeholder)) }
                .textFieldStyle(.plain).font(OMFonts.body)
            if !text.isEmpty {
                Button { text = "" } label: { Image.om("circle-x", size: 12).foregroundStyle(OMColors.tertiaryText) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(OMColors.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
    }
}

/// 空列表占位卡片(带主操作)。
struct ExtensionEmptyCard: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image.om(icon, size: 26).foregroundStyle(OMColors.tertiaryText)
            Text(verbatim: title).font(OMFonts.body.weight(.medium))
            Text(verbatim: message).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
    }
}
