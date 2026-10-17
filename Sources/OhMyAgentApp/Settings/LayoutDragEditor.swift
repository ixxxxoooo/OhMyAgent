// @author ixxxxoooo
// 外观页的「布局」编辑器:一个迷你工作台示意图,把「项目栏 / 工具栏 / 终端 / 输出」小卡片拖到
// 左栏、右栏、底部或编辑区即可摆放;与直接拖动面板标题条共用同一套落点逻辑(WorkbenchModel.place)。

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
        static let bottomHeight: CGFloat = 56
        static let gap: CGFloat = 6
    }

    var body: some View {
        HStack(spacing: Metrics.gap) {
            zoneView(.left).frame(width: Metrics.sideWidth)
            VStack(spacing: Metrics.gap) {
                zoneView(.editor)
                zoneView(.bottom).frame(height: Metrics.bottomHeight)
            }
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
                .strokeBorder(isTargeted ? OMColors.accent : OMColors.hairline, style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 0.5, dash: zone == .editor ? [] : [4, 3]))
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title(zone)).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                if zone.side == nil {
                    // 底部与编辑区较宽,卡片横向排列
                    HStack(spacing: 4) { ForEach(items) { chip($0) } }
                } else {
                    ForEach(items) { chip($0) }
                }
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
        .help(item.allowedZones.count == 2 ? String(localized: "拖到左栏或右栏") : String(localized: "拖到左栏、右栏、底部或编辑区"))
        .accessibilityLabel(Self.title(item))
        .accessibilityHint(String(localized: "拖动到其它区域可更换位置"))
    }

    private static func title(_ zone: PanelZone) -> String {
        switch zone {
        case .left: return String(localized: "左栏")
        case .right: return String(localized: "右栏")
        case .bottom: return String(localized: "底部")
        case .editor: return String(localized: "编辑区")
        }
    }

    private static func title(_ item: PanelItem) -> String {
        switch item {
        case .sidebar: return String(localized: "项目栏")
        case .tools: return String(localized: "文件 / Git")
        case .terminal: return String(localized: "终端")
        case .output: return String(localized: "输出")
        }
    }

    private static func icon(_ item: PanelItem) -> String {
        switch item {
        case .sidebar: return "panel-left"
        case .tools: return "panel-right"
        case .terminal: return "square-terminal"
        case .output: return "file-text"
        }
    }
}
