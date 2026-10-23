// @author ixxxxoooo
// Markdown 表格放大查看:悬停表格右上角出现放大按钮,点击后以模态卡片展示整张表格(宽松排版、单元格不折行,超宽/超高时可滚动)。

import AppKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 表格放大查看的呈现入口。
@MainActor
enum TableExpander {
    /// 卡片四周留给阴影的边距(与 `OMModal` 一致)
    private static let shadowInset: CGFloat = 28
    /// 卡片内边距
    private static let contentPadding: CGFloat = 16

    /// 以模态卡片放大展示表格;表头与数据行都为空时忽略。
    /// - Parameters:
    ///   - header: 表头
    ///   - rows: 数据行
    ///   - aligns: 每列对齐
    static func present(header: [String], rows: [[String]], aligns: [MarkdownTableAlign]) {
        guard !header.isEmpty || !rows.isEmpty else { return }
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let container = parent?.frame.size ?? CGSize(width: 1200, height: 800)
        let natural = naturalWidth(header: header, rows: rows, aligns: aligns)
        let maxWidth = max(container.width - 2 * shadowInset - 48, 480)
        let width = min(max(natural + 2 * contentPadding + 2, 480), maxWidth)
        let lineHeight = ceil(11.5 * OMScale.ui * 1.3) + 16 + 1
        let maxHeight = max(container.height * 0.8 - 60, 200)
        let height = min(CGFloat(rows.count + 1) * lineHeight + 4, maxHeight)
        OMModal.run(width: width) { handle in
            TableExpandCard(header: header, rows: rows, aligns: aligns, height: height) { handle.finish(-1) }
        }
    }

    /// 单行排版下整张表格的自然宽度。
    private static func naturalWidth(header: [String], rows: [[String]], aligns: [MarkdownTableAlign]) -> CGFloat {
        let text = OMLeafContent.table(header: header, rows: rows, aligns: aligns, roomy: true, maxWidth: nil)
        guard text.length > 0, let width = text.attribute(omIntrinsicWidthKey, at: 0, effectiveRange: nil) as? CGFloat else { return 0 }
        return width
    }
}

/// 放大后的表格卡片:顶栏(标题 + 关闭)与可滚动的表格。
private struct TableExpandCard: View {
    let header: [String]
    let rows: [[String]]
    let aligns: [MarkdownTableAlign]
    let height: CGFloat
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("表格").font(OMFonts.title).foregroundStyle(OMColors.primaryText)
                Spacer()
                Button(action: close) { Image.om("x", size: 14) }
                    .buttonStyle(.plain)
                    .foregroundStyle(OMColors.secondaryText)
                    .omTooltip("关闭")
                    .accessibilityLabel(String(localized: "关闭"))
            }
            ScrollView([.horizontal, .vertical]) {
                TableTextLeaf(header: header, rows: rows, aligns: aligns, roomy: true, availableWidth: nil)
                    .clipShape(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
                    .omSolidCard()
            }
            .frame(height: height)
        }
        .padding(16)
    }
}
