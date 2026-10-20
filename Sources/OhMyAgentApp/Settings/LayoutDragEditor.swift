// @author ixxxxoooo
// 外观页的「布局」编辑器:一个迷你工作台示意图,把「项目栏 / 右栏停靠区」小卡片拖到
// 左侧或右侧即可摆放;终端、输出、文件预览等是右栏停靠区里的标签,不再单独摆放。

import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 迷你工作台拖拽布局编辑器。
struct LayoutDragEditor: View {
    @Bindable var workbench: WorkbenchModel
    @State private var targeted: PanelZone?

    private enum Metrics {
        static let sideWidth: CGFloat = 120
        static let height: CGFloat = 176
        static let gap: CGFloat = 6
    }

    var body: some View {
        HStack(spacing: Metrics.gap) {
            zoneView(.left).frame(width: Metrics.sideWidth)
            RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous)
                .strokeBorder(OMColors.hairline, lineWidth: 0.5)
                .overlay { Text("编辑区").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText) }
            zoneView(.right).frame(width: Metrics.sideWidth)
        }
        .frame(height: Metrics.height)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("布局编辑器")
    }

    /// 一个摆放区域:标题 + 已放置的面板卡片;可接收面板拖入。
    private func zoneView(_ zone: PanelZone) -> some View {
        let items = workbench.layout.items(in: zone)
        let isTargeted = targeted == zone
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous)
                .fill(isTargeted ? OMColors.selectedFill : OMColors.card)
            RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous)
                .strokeBorder(isTargeted ? OMColors.accent : OMColors.hairline, style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 0.5, dash: [4, 3]))
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title(zone)).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                ForEach(items) { chip($0) }
                Spacer(minLength: 0)
            }
            .padding(8)
        }
        .dropDestination(for: String.self) { payloads, _ in
            guard let item = payloads.compactMap(PanelItem.parse(payload:)).first else { return false }
            var placed = false
            omWithAnimation { placed = workbench.place(item, in: zone) }
            return placed
        } isTargeted: { inside in
            if inside { targeted = zone } else if targeted == zone { targeted = nil }
        }
    }

    /// 可拖动的面板小卡片。
    private func chip(_ item: PanelItem) -> some View {
        HStack(spacing: 5) {
            Image.om(Self.icon(item), size: 11)
            Text(Self.title(item)).font(OMFonts.small).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 22)
        .background(OMColors.selectedFill, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
        .foregroundStyle(OMColors.accent)
        .draggable(item.payload)
        .omTooltip(String(localized: "拖到左栏或右栏"))
        .accessibilityLabel(Self.title(item))
        .accessibilityHint(String(localized: "拖动到其它区域可更换位置"))
    }

    private static func title(_ zone: PanelZone) -> String {
        switch zone {
        case .left: return String(localized: "左栏")
        case .right: return String(localized: "右栏")
        }
    }

    private static func title(_ item: PanelItem) -> String {
        switch item {
        case .sidebar: return String(localized: "项目栏")
        case .tools: return String(localized: "右栏停靠区")
        }
    }

    private static func icon(_ item: PanelItem) -> String {
        switch item {
        case .sidebar: return "panel-left"
        case .tools: return "panel-right"
        }
    }
}
