// @author ixxxxoooo
// 用户长消息:超过阈值自动收起为固定行数,悬停时可在窗口内滚动,点击「展开」查看更多(超过上限后内部滚动)。

import DesignSystem
import IconKit
import SwiftUI

/// 长消息折叠的纯逻辑(与视图分离,便于测试)。
enum LongMessagePolicy {
    /// 收起时可见的行数
    static let collapsedLines = 6
    /// 展开后最多可见的行数(再长则内部滚动)
    static let expandedMaxLines = 24
    /// 粗略估算每行可容纳的字符数(中英文混排取折中值)
    static let charsPerLine = 48

    /// 按文本粗估渲染行数:显式换行 + 长行折行。
    /// - Parameter text: 消息文本
    /// - Returns: 估算行数(≥ 1,空文本为 0)
    static func estimatedLines(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) / Double(charsPerLine)).rounded(.up))) }
    }

    /// 是否可能需要折叠(渲染前的启发式,渲染后以实际测量高度为准)。
    static func isLikelyLong(_ text: String) -> Bool { estimatedLines(text) > collapsedLines }

    /// 根据测得的内容高度决定窗口高度。
    /// - Parameters:
    ///   - content: 文本实际高度(0 表示尚未测量)
    ///   - lineHeight: 单行行高
    ///   - expanded: 是否已展开
    /// - Returns: 窗口高度;内容不超过收起高度时返回内容高度(不折叠)
    static func windowHeight(content: CGFloat, lineHeight: CGFloat, expanded: Bool) -> CGFloat {
        let collapsed = lineHeight * CGFloat(collapsedLines)
        guard content > 0 else { return collapsed }
        if content <= collapsed + lineHeight * 0.5 { return content }
        return expanded ? min(content, lineHeight * CGFloat(expandedMaxLines)) : collapsed
    }

    /// 实测内容是否确实需要折叠。
    /// - Parameters:
    ///   - content: 文本实际高度
    ///   - lineHeight: 单行行高
    ///   - wasCollapsible: 此前是否已处于折叠形态:是则用较低的退出阈值(滞回),
    ///     避免窗口宽度在边界附近抖动时在「折叠/平铺」两种视图结构间来回切换
    static func needsCollapse(content: CGFloat, lineHeight: CGFloat, wasCollapsible: Bool = false) -> Bool {
        content > lineHeight * (CGFloat(collapsedLines) + (wasCollapsible ? 0.25 : 0.5))
    }
}

/// 用户消息正文:短消息原样显示,长消息折叠成固定高度窗口(底部渐隐),悬停可滚动,右下角「展开/收起」。
struct CollapsibleUserText: View {
    let text: String
    @State private var expanded = false
    @State private var hovering = false
    @State private var contentHeight: CGFloat = 0
    /// 上一次是否处于折叠形态(折叠阈值滞回用)
    @State private var wasCollapsible = false

    private var lineHeight: CGFloat { 13 * OMScale.ui * OMScale.timeline * OMFonts.readingLineHeightRatio }

    var body: some View {
        if LongMessagePolicy.isLikelyLong(text) || LongMessagePolicy.needsCollapse(content: contentHeight, lineHeight: lineHeight, wasCollapsible: wasCollapsible) {
            collapsible
        } else {
            // 短消息也测量一次高度:窄窗口下折行超出估算时自动转为折叠
            plainText
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0; wasCollapsible = false }
        }
    }

    private var plainText: some View {
        Text(text)
            .font(OMFonts.reading)
            .lineSpacing(OMFonts.readingLineSpacing)
            .textSelection(.enabled)
    }

    private var collapsible: some View {
        let height = LongMessagePolicy.windowHeight(content: contentHeight, lineHeight: lineHeight, expanded: expanded)
        let overflows = LongMessagePolicy.needsCollapse(content: contentHeight, lineHeight: lineHeight, wasCollapsible: wasCollapsible)
        return VStack(alignment: .leading, spacing: 4) {
            ScrollView(.vertical, showsIndicators: hovering) {
                plainText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0; wasCollapsible = true }
            }
            // 仅悬停时可在窗口内滚动;其余时间滚轮交给外层会话流
            .scrollDisabled(!hovering)
            .frame(height: height)
            // 仅在「收起且内容溢出」时才挂底部渐隐 mask:mask 会让整块走离屏渲染,不溢出/已展开时不付这笔开销
            .omBottomFade(enabled: overflows && !expanded)
            .onHover { hovering = $0 }
            if overflows {
                Button {
                    omWithAnimation { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? String(localized: "收起") : String(localized: "展开"))
                        Image.om(expanded ? "chevron-up" : "chevron-down", size: 10)
                    }
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .omTooltip(expanded ? String(localized: "收起长消息") : String(localized: "展开全部内容"))
                .accessibilityLabel(expanded ? String(localized: "收起长消息") : String(localized: "展开全部内容"))
            }
        }
    }
}

private extension View {
    /// 底部渐隐遮罩,仅 `enabled` 时才挂(`.mask` 会让整块走离屏渲染)。
    /// 两个分支都用 `.identity` 过渡,切换时不会出现交叉淡入淡出。
    @ViewBuilder
    func omBottomFade(enabled: Bool) -> some View {
        if enabled {
            mask {
                LinearGradient(stops: [.init(color: OMColors.maskInk, location: 0), .init(color: OMColors.maskInk, location: 0.78), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom) // ui-lint:allow 仅作遮罩/淡出,非装饰
            }
            .transition(.identity)
        } else {
            transition(.identity)
        }
    }
}
