// @author ixxxxoooo
// 标签栏(对齐 kuku 的 CenterTabs / TabItem / TabOverflowMenu):
// 圆角胶囊标签(未激活态浅灰底,激活态融入内容区)、悬停显示关闭、固定标签显示图钉、标签放不下时右端出现「全部标签」下拉、
// 中键关闭、激活标签自动滚动到可见。切换标签在鼠标按下抬起时立即生效(不再等待双击判定)。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 标签栏尺寸常量。
private enum TabMetrics {
    /// 标签高度(kuku 的 control-h-base)
    static let height: CGFloat = 28
    static let radius: CGFloat = 6
    static let spacing: CGFloat = 4
    /// 标签文字最大宽度
    static let labelMaxWidth: CGFloat = 180
}

/// 标签栏。
struct TabBarView: View {
    let workbench: WorkbenchModel
    let group: TabGroup
    let isFocused: Bool
    /// 左侧让位宽度(侧栏收起时,为红绿灯与左上浮层按钮留位)
    var leadingInset: CGFloat = 0
    /// 右侧让位宽度(右栏收起时,为右上角右栏开关留位)
    var trailingInset: CGFloat = 0
    /// 标签是否超出可视宽度(决定是否显示「全部标签」下拉)
    @State private var overflowing = false
    /// 滚动区可视宽度:标签内容至少撑满它,尾部空白才都归窗口拖动区
    @State private var stripWidth: CGFloat = 0
    @State private var showOverflow = false

    /// 是否为第一个(主)标签组。
    private var isMainGroup: Bool { workbench.dock.groups.first?.id == group.id }

    var body: some View {
        HStack(spacing: 0) {
            if leadingInset > 0 { Color.clear.frame(width: leadingInset).background(WindowDragArea()) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TabMetrics.spacing) {
                        ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabItemView(workbench: workbench, group: group, tab: tab, isActive: tab.id == group.activeID, isFocused: isFocused)
                                .id(tab.id)
                                .onDrop(of: [.plainText, .fileURL], delegate: TabStripDropDelegate(workbench: workbench, groupID: group.id, index: index))
                        }
                        Color.clear
                            .frame(minWidth: 24, maxWidth: .infinity)
                            .windowDragGesture()
                    }
                    .padding(.horizontal, 8)
                    .frame(minWidth: stripWidth, alignment: .leading)
                }
                // 放到标签之间/末尾空白处:追加到末尾(单个标签上的落点代理优先)
                .onDrop(of: [.plainText, .fileURL], delegate: TabStripDropDelegate(workbench: workbench, groupID: group.id, index: nil))
                .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, value in
                    stripWidth = value
                }
                .onScrollGeometryChange(for: Bool.self) { $0.contentSize.width > $0.containerSize.width + 1 } action: { _, value in
                    overflowing = value
                }
                .task(id: overflowing) {
                    // 调试钩子:OMA_TAB_OVERFLOW=1 在标签溢出时自动展开「全部标签」下拉(脚本化界面验证用)
                    if overflowing, isMainGroup, ProcessInfo.processInfo.environment["OMA_TAB_OVERFLOW"] != nil {
                        try? await Task.sleep(for: .milliseconds(500))
                        showOverflow = true
                    }
                }
                .onChange(of: group.activeID) { _, id in
                    guard let id else { return }
                    omWithAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if overflowing {
                overflowButton
            }
            if trailingInset > 0 { Color.clear.frame(width: trailingInset).background(WindowDragArea()) }
        }
        .frame(height: TitlebarMetrics.height)
        .background(OMColors.surface)
    }

    /// 标签放不下时右端的「全部标签」下拉入口。
    private var overflowButton: some View {
        Button { showOverflow.toggle() } label: {
            Image.om("chevron-down", size: 13)
                .frame(width: TabMetrics.height, height: TabMetrics.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabBarIconButtonStyle())
        .padding(.trailing, 4)
        .omTooltip("全部标签")
        .accessibilityLabel("全部标签")
        .omCustomPicker(isPresented: $showOverflow, placement: .below, width: 350) {
            TabOverflowList(workbench: workbench, group: group) { showOverflow = false }
        }
    }
}

/// 标签栏图标按钮样式:弱化前景色,悬停时出现浅色底。
private struct TabBarIconButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? OMColors.primaryText : OMColors.secondaryText)
            .background(OMColors.primaryText.opacity(hovering || configuration.isPressed ? 0.07 : 0), in: RoundedRectangle(cornerRadius: TabMetrics.radius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

/// 单个标签:胶囊背景(未激活态浅灰,悬停加深;激活态透明并融入内容区)+ 图标 + 标题 + 运行态/未保存点 + 关闭按钮(悬停显示)。
struct TabItemView: View {
    let workbench: WorkbenchModel
    let group: TabGroup
    let tab: WorkbenchTab
    let isActive: Bool
    let isFocused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(workbench.displayTitle(tab))
                .font(OMFonts.small)
                .italic(tab.isPreview)
                .lineLimit(1)
                .frame(maxWidth: TabMetrics.labelMaxWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                // 尾部有状态/关闭按钮时,标题末端淡出,避免与之重叠
                .mask(
                    HStack(spacing: 0) {
                        Rectangle()
                        if showsTrailing {
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 60) // ui-lint:allow 仅作遮罩/淡出,非装饰
                        }
                    }
                )
        }
        .padding(.horizontal, 8)
        // 关闭按钮/状态点叠在标签右端,不单独占位
        .overlay(alignment: .trailing) { trailing.padding(.trailing, 6) }
        .frame(height: TabMetrics.height)
        .foregroundStyle(isActive ? OMColors.secondaryText : OMColors.primaryText)
        .background(
            RoundedRectangle(cornerRadius: TabMetrics.radius, style: .continuous)
                .fill(isActive ? (hovering ? OMColors.subtleFill : Color.clear) : (hovering ? OMColors.pressedFill : OMColors.hoverFill))
        )
        .contentShape(RoundedRectangle(cornerRadius: TabMetrics.radius, style: .continuous))
        .transaction { $0.animation = nil }
        .onHover { hovering = $0 }
        // 单击立即切换:单击与双击分属两个同时识别的手势,单击不再等待双击判定窗口
        .onTapGesture { workbench.activateTab(tab.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("关闭标签")) { AppActions.shared.requestCloseTab(tab.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if tab.isPreview { workbench.dock.keepOpen(tab.id) } else { workbench.dock.toggleMaximize(group: group.id) }
        })
        .background(MiddleClickCatcher {
            if !tab.isPinned { AppActions.shared.requestCloseTab(tab.id) }
        })
        // 拖拽时源标签隐藏、只显示自定义拖影,避免原位与拖影叠成重影
        .opacity(DockDrag.shared.tabID == tab.id ? 0 : 1)
        .onDrag {
            DockDrag.shared.begin(tab.id)
            return NSItemProvider(object: (DockDrag.prefix + tab.id.uuidString) as NSString)
        } preview: {
            TabDragPreview(title: workbench.displayTitle(tab), tab: tab)
        }
        .omContextMenu { menu }
        .omTooltip(helpText)
    }

    /// 类型图标:文件用彩色文件类型图标,其余用 Lucide 图标。
    @ViewBuilder
    private var icon: some View {
        if case .file(let path) = tab.kind {
            OMFileIcon(name: (path as NSString).lastPathComponent, size: 14)
                .opacity(isActive ? 0.75 : 1)
        } else {
            Image.om(tabIcon(tab.kind), size: 12)
                .foregroundStyle(isActive ? OMColors.tertiaryText : OMColors.primaryText)
        }
    }

    /// 会话标签的注意力状态(运行中/等待/未读);非会话标签为 idle。
    private var attentionState: AttentionState {
        guard case .chat = tab.kind, let uid = workbench.session(forTab: tab)?.uid else { return .idle }
        return AttentionCenter.shared.items[uid]?.state ?? .idle
    }

    /// 尾部是否有内容(悬停的关闭按钮、图钉、未保存点或会话状态点)。
    private var showsTrailing: Bool {
        hovering || tab.isPinned || tab.isDirty || attentionState != .idle
    }

    /// 尾部叠加区:悬停显示关闭按钮;否则显示图钉 / 未保存点 / 会话状态点(运行中为呼吸灯)。
    @ViewBuilder
    private var trailing: some View {
        ZStack {
            if tab.isPinned {
                Button { workbench.dock.togglePinned(tab.id) } label: {
                    Image.om("pin", size: 10).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .omTooltip("取消固定")
                .accessibilityLabel("取消固定")
            } else {
                if !hovering {
                    if tab.isDirty {
                        Circle().fill(OMColors.secondaryText).frame(width: 7, height: 7)
                            .omTooltip("有未保存修改")
                    } else if case .chat = tab.kind, let uid = workbench.session(forTab: tab)?.uid {
                        AttentionDot(uid: uid)
                    }
                }
                if hovering {
                    Button { AppActions.shared.requestCloseTab(tab.id) } label: {
                        Image.om("x", size: 11).frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OMColors.secondaryText)
                    .omTooltip("关闭标签")
                    .accessibilityLabel("关闭标签")
                }
            }
        }
        .frame(width: 16, height: 16)
    }

    private var helpText: String {
        switch tab.kind {
        case .file(let path), .diff(let path): return (path as NSString).abbreviatingWithTildeInPath
        default: return workbench.displayTitle(tab)
        }
    }

    /// 终端/输出标签的「移到…」菜单:把它们从编辑区放回底部或左右侧栏(与标题条拖动等价)。
    @OMMenuBuilder
    private var panelMoveEntries: [MenuEntry] {
        if let item = panelItem {
            OMMenuDivider()
            for zone in item.allowedZones.filter({ $0 != .editor }) {
                OMMenuItem(verbatim: Self.moveTitle(item: item, zone: zone), icon: zone == .left ? "panel-left" : (zone == .bottom ? "panel-bottom" : "panel-right")) { omWithAnimation { _ = workbench.place(item, in: zone) } }
            }
        }
    }

    /// 标签对应的可摆放面板(仅终端标签与输出标签)。
    private var panelItem: PanelItem? {
        switch tab.kind {
        case .terminal, .agentTerminal: return .terminal
        case .preview(let id): return id == WorkbenchModel.outputTabID ? .output : nil
        default: return nil
        }
    }

    private static func moveTitle(item: PanelItem, zone: PanelZone) -> String {
        switch zone {
        case .bottom: return String(localized: "移到底部面板")
        case .left: return String(localized: "移到左侧栏")
        case .right: return String(localized: "移到右侧栏")
        case .editor: return String(localized: "移到编辑区")
        }
    }

    /// 本标签右侧的标签 ID。
    private var rightIDs: Set<UUID> {
        guard let index = group.tabs.firstIndex(where: { $0.id == tab.id }) else { return [] }
        return Set(group.tabs[(index + 1)...].map(\.id))
    }

    /// 同组内满足条件、且未固定的标签 ID(批量关闭不动固定标签)。
    private func closableIDs(_ matching: (WorkbenchTab) -> Bool) -> [UUID] {
        group.tabs.filter { !$0.isPinned && matching($0) }.map(\.id)
    }

    @OMMenuBuilder
    private var menu: [MenuEntry] {
        OMMenuItem("关闭", icon: "x") { AppActions.shared.requestCloseTab(tab.id) }
        OMMenuItem("关闭其它", isEnabled: !closableIDs { $0.id != tab.id }.isEmpty) { AppActions.shared.requestCloseTabs(closableIDs { $0.id != tab.id }) }
        OMMenuItem("关闭右侧", isEnabled: !closableIDs { rightIDs.contains($0.id) }.isEmpty) { AppActions.shared.requestCloseTabs(closableIDs { rightIDs.contains($0.id) }) }
        OMMenuItem("关闭全部", isEnabled: !closableIDs { _ in true }.isEmpty) { AppActions.shared.requestCloseTabs(closableIDs { _ in true }) }
        if case .chat(let projectID, _) = tab.kind, let sessionId = workbench.session(forTab: tab)?.sessionId {
            OMMenuDivider()
            OMMenuItem("重命名标签…", icon: "pencil") {
                guard let name = ExplorerActions.prompt(title: String(localized: "重命名会话"), initial: workbench.displayTitle(tab)) else { return }
                workbench.renameSession(sessionId, in: projectID, to: name)
            }
        }
        OMMenuDivider()
        OMMenuItem(verbatim: tab.isPinned ? String(localized: "取消固定") : String(localized: "固定"), icon: "pin") { workbench.dock.togglePinned(tab.id) }
        OMMenuItem("向右拆分", icon: "columns-2", isEnabled: group.tabs.count >= 2) {
            workbench.dock.drop(tab.id, onGroup: group.id, zone: .right)
            workbench.syncSelectionFromDock()
        }
        OMMenuItem(verbatim: workbench.dock.maximizedGroupID == group.id ? String(localized: "还原布局") : String(localized: "最大化此组"), icon: "maximize-2") { workbench.dock.toggleMaximize(group: group.id) }
        panelMoveEntries
        if case .file(let path) = tab.kind {
            OMMenuDivider()
            OMMenuItem("在 Finder 中显示", icon: "folder-open") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            OMMenuItem("拷贝路径", icon: "copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }
}

/// 标签拖影:只含图标与标题的胶囊(不带窗口标题或标签栏背景)。
private struct TabDragPreview: View {
    let title: String
    let tab: WorkbenchTab

    var body: some View {
        HStack(spacing: 5) {
            if case .file(let path) = tab.kind {
                OMFileIcon(name: (path as NSString).lastPathComponent, size: 14)
            } else {
                Image.om(tabIcon(tab.kind), size: 12).foregroundStyle(OMColors.secondaryText)
            }
            Text(title).font(OMFonts.small).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: TabMetrics.height)
        .background(OMColors.surface, in: RoundedRectangle(cornerRadius: TabMetrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TabMetrics.radius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
    }
}

// MARK: - 「全部标签」下拉

/// 「全部标签」弹层:标题 + 数量、标签较多时的即时搜索、双行条目(标题 + 路径摘要)、同名序号、悬停关闭。
struct TabOverflowList: View {
    let workbench: WorkbenchModel
    let group: TabGroup
    let dismiss: () -> Void
    @State private var filter = ""

    /// 搜索框出现的标签数量阈值(对齐 kuku)
    private static let searchThreshold = 6

    /// 每个标签的展示信息(标题、副标题、同名序号)。
    fileprivate struct Item: Identifiable {
        let tab: WorkbenchTab
        let title: String
        let subtitle: String
        let duplicate: Int?
        var id: UUID { tab.id }
    }

    private var items: [Item] {
        let titles = group.tabs.map { workbench.displayTitle($0) }
        var counts: [String: Int] = [:]
        titles.forEach { counts[$0, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return zip(group.tabs, titles).map { tab, title in
            var duplicate: Int?
            if counts[title, default: 0] > 1 {
                seen[title, default: 0] += 1
                duplicate = seen[title]
            }
            return Item(tab: tab, title: title, subtitle: Self.subtitle(of: tab), duplicate: duplicate)
        }
    }

    /// 次级说明:文件/Diff 显示路径,会话显示项目路径,其余显示类型。
    private static func subtitle(of tab: WorkbenchTab) -> String {
        switch tab.kind {
        case .file(let path), .diff(let path), .blame(let path): return (path as NSString).abbreviatingWithTildeInPath
        case .chat(let id, _), .changes(let id), .history(let id, _): return (id as NSString).abbreviatingWithTildeInPath
        case .subagent: return String(localized: "子 Agent 会话")
        case .terminal, .agentTerminal: return String(localized: "终端")
        case .preview: return String(localized: "预览")
        }
    }

    var body: some View {
        PickListContent(
            items: items.map { TabPick(id: $0.tab.id.uuidString, item: $0) },
            selectedID: group.activeID?.uuidString,
            placeholder: String(localized: "搜索标签名称或路径…"),
            showsSearch: group.tabs.count >= Self.searchThreshold,
            maxListHeight: 380,
            emptyText: String(localized: "未找到匹配的标签"),
            row: { TabOverflowRow(workbench: workbench, item: $0.item) },
            onSelect: { pick in
                workbench.activateTab(pick.item.tab.id)
                dismiss()
            },
            onDismiss: dismiss
        )
    }
}

/// 「全部标签」的一项(包装展示信息以满足选择列表协议)。
private struct TabPick: PickListItem {
    let id: String
    fileprivate let item: TabOverflowList.Item

    var searchText: String { "\(item.title) \(item.subtitle)" }
}

/// 下拉中的一行:图标 + 标题(含同名序号)+ 路径摘要;右侧运行/未保存点,悬停时出现关闭按钮。
private struct TabOverflowRow: View {
    let workbench: WorkbenchModel
    let item: TabOverflowList.Item
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 16, height: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(OMFonts.small)
                        .lineLimit(1)
                    if let duplicate = item.duplicate {
                        Text("#\(duplicate)")
                            .font(OMFonts.caption.monospacedDigit())
                            .foregroundStyle(OMColors.secondaryText)
                            .padding(.horizontal, 4)
                            .background(OMColors.hoverFill, in: RoundedRectangle(cornerRadius: OMRadius.tag))
                    }
                    if item.tab.isDirty { Circle().fill(OMColors.warning).frame(width: 6, height: 6).omTooltip("有未保存修改") }
                    if case .chat = item.tab.kind, let uid = workbench.session(forTab: item.tab)?.uid {
                        AttentionDot(uid: uid)
                    }
                }
                Text(item.subtitle)
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button { AppActions.shared.requestCloseTab(item.tab.id) } label: {
                Image.om("x", size: 12).frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(OMColors.secondaryText)
            .opacity(hovering ? 1 : 0)
            .omTooltip("关闭标签")
            .accessibilityLabel("关闭标签")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .background(MiddleClickCatcher { if !item.tab.isPinned { AppActions.shared.requestCloseTab(item.tab.id) } })
    }

    @ViewBuilder
    private var icon: some View {
        if case .file(let path) = item.tab.kind {
            OMFileIcon(name: (path as NSString).lastPathComponent, size: 14)
        } else {
            Image.om(tabIcon(item.tab.kind), size: 12).foregroundStyle(OMColors.secondaryText)
        }
    }

}
