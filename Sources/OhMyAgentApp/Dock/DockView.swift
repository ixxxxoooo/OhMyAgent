// @author ixxxxoooo
// 停靠区根视图:递归渲染分屏树;分隔条可拖动调整比例;组被最大化时只显示该组。

import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 当前视图子树所属的停靠区(中栏或右栏);标签栏、标签组、落点代理据此读写对应的 `DockLayout`。
private struct DockHostKey: EnvironmentKey {
    static let defaultValue: DockHost = .center
}

extension EnvironmentValues {
    /// 所属停靠区。
    var dockHost: DockHost {
        get { self[DockHostKey.self] }
        set { self[DockHostKey.self] = newValue }
    }
}

/// 停靠区(中栏与右栏共用)。
struct DockView: View {
    @Bindable var workbench: WorkbenchModel
    var host: DockHost = .center

    var body: some View {
        let layout = workbench.dock(host)
        Group {
            if let id = layout.maximizedGroupID, let group = layout.group(id) {
                TabGroupView(workbench: workbench, group: group)
            } else {
                DockNodeView(workbench: workbench, node: layout.root)
            }
        }
        .environment(\.dockHost, host)
    }
}

/// 递归节点:组 → 标签组视图;分屏 → 分屏视图。
struct DockNodeView: View {
    let workbench: WorkbenchModel
    let node: DockNode
    /// 该节点贴着窗口哪几条边(其标签栏需要在侧栏/右栏收起时为浮层按钮让位)
    var edges = DockEdges()

    var body: some View {
        switch node {
        case .group(let group): TabGroupView(workbench: workbench, group: group, edges: edges)
        case .split(let split): DockSplitView(workbench: workbench, split: split, edges: edges)
        }
    }
}

/// 分屏:按 ratios 分配空间,子节点之间放置可拖动的分隔条。
struct DockSplitView: View {
    let workbench: WorkbenchModel
    @Environment(\.dockHost) private var host
    let split: DockSplit
    var edges = DockEdges()
    @State private var dragBase: [Double]?
    /// 拖动中暂存的比例:拖动期间只改这个本地状态(仅本分屏重排),松手才写回 `dock`,
    /// 避免每个 tick 都让整个停靠布局(及所有观察 dock 的视图)失效。
    @State private var liveRatios: [Double]?

    private var horizontal: Bool { split.axis == .horizontal }

    var body: some View {
        GeometryReader { proxy in
            let total = horizontal ? proxy.size.width : proxy.size.height
            let usable = max(total - Self.handle * CGFloat(split.children.count - 1), 1)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(split.children.enumerated()), id: \.element.id) { index, child in
                    DockNodeView(workbench: workbench, node: child, edges: edges.child(at: index, of: split.children.count, horizontal: horizontal))
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
        let ratios = liveRatios ?? split.ratios
        return ratios.indices.contains(index) ? ratios[index] : 1.0 / Double(max(split.children.count, 1))
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
                                if dragBase == nil { dragBase = base; PanelDragState.shared.beginHold() }
                                guard base.indices.contains(index + 1) else { return }
                                let delta = Double((horizontal ? value.translation.width : value.translation.height) / usable)
                                var next = base
                                next[index] = base[index] + delta
                                next[index + 1] = base[index + 1] - delta
                                liveRatios = DockLayout.normalizedRatios(next)
                            }
                            .onEnded { _ in
                                if dragBase != nil { PanelDragState.shared.endHold() }
                                dragBase = nil
                                if let committed = liveRatios { workbench.mutateDock(host) { $0.setRatios(committed, forSplit: split.id) } }
                                liveRatios = nil
                            }
                    )
            }
            .accessibilityHidden(true)
    }
}
