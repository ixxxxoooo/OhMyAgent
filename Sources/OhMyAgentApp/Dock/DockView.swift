// @author ygw
// 停靠区根视图:递归渲染分屏树;分隔条可拖动调整比例;组被最大化时只显示该组。

import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 停靠区。
struct DockView: View {
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        if let id = workbench.dock.maximizedGroupID, let group = workbench.dock.group(id) {
            TabGroupView(workbench: workbench, group: group, topLeft: true)
        } else {
            DockNodeView(workbench: workbench, node: workbench.dock.root, topLeft: true)
        }
    }
}

/// 递归节点:组 → 标签组视图;分屏 → 分屏视图。
struct DockNodeView: View {
    let workbench: WorkbenchModel
    let node: DockNode
    /// 该节点是否位于停靠区左上角(其标签栏需要在侧栏收起时为浮层按钮让位)
    var topLeft = false

    var body: some View {
        switch node {
        case .group(let group): TabGroupView(workbench: workbench, group: group, topLeft: topLeft)
        case .split(let split): DockSplitView(workbench: workbench, split: split, topLeft: topLeft)
        }
    }
}

/// 分屏:按 ratios 分配空间,子节点之间放置可拖动的分隔条。
struct DockSplitView: View {
    let workbench: WorkbenchModel
    let split: DockSplit
    var topLeft = false
    @State private var dragBase: [Double]?

    private var horizontal: Bool { split.axis == .horizontal }

    var body: some View {
        GeometryReader { proxy in
            let total = horizontal ? proxy.size.width : proxy.size.height
            let usable = max(total - Self.handle * CGFloat(split.children.count - 1), 1)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(split.children.enumerated()), id: \.element.id) { index, child in
                    DockNodeView(workbench: workbench, node: child, topLeft: topLeft && index == 0)
                        .frame(
                            width: horizontal ? max(usable * ratio(index), 0) : nil,
                            height: horizontal ? nil : max(usable * ratio(index), 0)
                        )
                        .clipped()
                    if index < split.children.count - 1 {
                        divider(after: index, usable: usable)
                    }
                }
            }
        }
    }

    private static let handle: CGFloat = 1

    private func ratio(_ index: Int) -> Double {
        split.ratios.indices.contains(index) ? split.ratios[index] : 1.0 / Double(max(split.children.count, 1))
    }

    /// 1pt 可见线 + 8pt 命中区的分隔条。
    private func divider(after index: Int, usable: CGFloat) -> some View {
        Rectangle()
            .fill(OMColors.hairline)
            .frame(width: horizontal ? Self.handle : nil, height: horizontal ? nil : Self.handle)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? 8 : nil, height: horizontal ? nil : 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragBase ?? split.ratios
                                if dragBase == nil { dragBase = base }
                                let delta = Double((horizontal ? value.translation.width : value.translation.height) / usable)
                                var next = base
                                next[index] = base[index] + delta
                                next[index + 1] = base[index + 1] - delta
                                workbench.dock.setRatios(next, forSplit: split.id)
                            }
                            .onEnded { _ in dragBase = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}
