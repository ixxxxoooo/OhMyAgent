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
    static func needsCollapse(content: CGFloat, lineHeight: CGFloat) -> Bool {
        content > lineHeight * (CGFloat(collapsedLines) + 0.5)
    }
}

/// 用户消息正文:短消息原样显示,长消息折叠成固定高度窗口(底部渐隐),悬停可滚动,右下角「展开/收起」。
struct CollapsibleUserText: View {
    let text: String
    @State private var expanded = false
    @State private var hovering = false
    @State private var contentHeight: CGFloat = 0

    private var lineHeight: CGFloat { 13 * OMScale.ui * OMScale.timeline * OMFonts.readingLineHeightRatio }

    var body: some View {
        if LongMessagePolicy.isLikelyLong(text) || LongMessagePolicy.needsCollapse(content: contentHeight, lineHeight: lineHeight) {
            collapsible
        } else {
            // 短消息也测量一次高度:窄窗口下折行超出估算时自动转为折叠
            plainText
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
    }

    private var plainText: some View {
        Text(text)
            .font(OMFonts.reading)
            .lineSpacing(OMFonts.readingLineSpacing)
    }

    private var collapsible: some View {
        let height = LongMessagePolicy.windowHeight(content: contentHeight, lineHeight: lineHeight, expanded: expanded)
        let overflows = LongMessagePolicy.needsCollapse(content: contentHeight, lineHeight: lineHeight)
        return VStack(alignment: .leading, spacing: 4) {
            ScrollView(.vertical, showsIndicators: hovering) {
                plainText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // 仅悬停时可在窗口内滚动;其余时间滚轮交给外层会话流
            .scrollDisabled(!hovering)
            .frame(height: height)
            .mask {
                // 收起且内容溢出时底部渐隐,提示还有更多
                if overflows && !expanded {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.78), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom) // ui-lint:allow 仅作遮罩/淡出,非装饰
                } else {
                    Rectangle()
                }
            }
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
