// @author ixxxxoooo
// 自动换行的横向流式布局:子视图按自身尺寸从左到右排列,超出宽度换行。

import SwiftUI

/// 自动换行的横向流式布局(标签列表、图例等)。
struct OMFlowLayout: Layout {
    /// 同一行内的横向间距
    var spacing: CGFloat = 6
    /// 行间距(为 nil 时与横向间距相同)
    var lineSpacing: CGFloat? = nil

    /// 按提议宽度排布后的总尺寸。
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    /// 逐个放置子视图。
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    /// 计算各子视图的位置与整体尺寸。
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + (lineSpacing ?? spacing)
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
