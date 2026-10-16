// @author ixxxxoooo
// 标签栏(对齐 kuku 的 CenterTabs / TabItem / TabOverflowMenu):
// 圆角胶囊标签(激活态浅灰底)、悬停显示关闭、固定标签显示图钉、标签放不下时右端出现「全部标签」下拉、
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
    @State private var showOverflow = false

    /// 是否为第一个(主)标签组:只有它显示「+ 新对话」按钮。
    private var isMainGroup: Bool { workbench.dock.groups.first?.id == group.id }

    var body: some View {
        HStack(spacing: 0) {
            if leadingInset > 0 { Color.clear.frame(width: leadingInset) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TabMetrics.spacing) {
                        ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabItemView(workbench: workbench, group: group, tab: tab, isActive: tab.id == group.activeID, isFocused: isFocused)
                                .id(tab.id)
                                .onDrop(of: [.plainText, .fileURL], delegate: TabStripDropDelegate(workbench: workbench, groupID: group.id, index: index))
                        }
                        if isMainGroup { newConversationButton }
                        Color.clear
                            .frame(minWidth: 24, maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onDrop(of: [.plainText, .fileURL], delegate: TabStripDropDelegate(workbench: workbench, groupID: group.id, index: nil))
                    }
                    .padding(.horizontal, 8)
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
            if overflowing { overflowButton }
            if trailingInset > 0 { Color.clear.frame(width: trailingInset) }
        }
        .frame(height: TitlebarMetrics.height)
        .background(WindowDragArea())
        .background(OMColors.surface)
    }

    /// 紧跟最后一个标签的「+」:在当前项目开始新对话。
    private var newConversationButton: some View {
        Button {
            if let id = workbench.selectedProjectID { workbench.newConversation(in: id) }
        } label: {
            Image.om("plus", size: 13)
                .frame(width: TabMetrics.height, height: TabMetrics.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabBarIconButtonStyle())
        .disabled(workbench.selectedProjectID == nil)
        .help(String(localized: "新对话") + " (\(ShortcutStore.shared.binding(for: .newConversation).display))")
        .accessibilityLabel("新对话")
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
        .help("全部标签")
        .accessibilityLabel("全部标签")
        .popover(isPresented: $showOverflow, arrowEdge: .bottom) {
            TabOverflowList(workbench: workbench, group: group) { showOverflow = false }
        }
    }
}

/// 标签栏图标按钮样式:弱化前景色,悬停时出现浅色底。
private struct TabBarIconButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? Color.primary : OMColors.secondaryText)
            .background(Color.primary.opacity(hovering || configuration.isPressed ? 0.07 : 0), in: RoundedRectangle(cornerRadius: TabMetrics.radius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

/// 单个标签:胶囊背景(激活态浅灰,悬停更浅)+ 图标 + 标题 + 运行态/未保存点 + 关闭按钮(悬停显示)。
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
            if case .chat(let projectID) = tab.kind, let uid = workbench.sessions[projectID]?.uid {
                AttentionDot(uid: uid)
            }
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: TabMetrics.height)
        .foregroundStyle(isActive ? Color.primary : OMColors.secondaryText)
        .background(
            RoundedRectangle(cornerRadius: TabMetrics.radius, style: .continuous)
                .fill(isActive ? Color.primary.opacity(0.07) : (hovering ? Color.primary.opacity(0.045) : Color.clear))
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
        .onDrag {
            DockDrag.shared.tabID = tab.id
            return NSItemProvider(object: (DockDrag.prefix + tab.id.uuidString) as NSString)
        }
        .contextMenu { menu }
        .help(helpText)
    }

    /// 类型图标:文件用彩色文件类型图标,其余用 Lucide 图标。
    @ViewBuilder
    private var icon: some View {
        if case .file(let path) = tab.kind {
            OMFileIcon(name: (path as NSString).lastPathComponent, size: 14)
                .opacity(isActive ? 1 : 0.75)
        } else {
            Image.om(tabIcon(tab.kind), size: 12)
                .foregroundStyle(isActive ? Color.primary : OMColors.tertiaryText)
        }
    }

    /// 尾部固定 16pt 保留区:固定图钉 / 未保存点(悬停时换成关闭按钮)/ 关闭按钮(仅悬停显示)。
    @ViewBuilder
    private var trailing: some View {
        ZStack {
            if tab.isPinned {
                Button { workbench.dock.togglePinned(tab.id) } label: {
                    Image.om("pin", size: 10).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .help("取消固定")
                .accessibilityLabel("取消固定")
            } else {
                if tab.isDirty && !hovering {
                    Circle().fill(OMColors.secondaryText).frame(width: 7, height: 7)
                        .help("有未保存修改")
                }
                if hovering {
                    Button { AppActions.shared.requestCloseTab(tab.id) } label: {
                        Image.om("x", size: 11).frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OMColors.secondaryText)
                    .help("关闭标签")
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

    @ViewBuilder
    private var menu: some View {
        Button("关闭") { AppActions.shared.requestCloseTab(tab.id) }
        Button("关闭其它") { workbench.dock.closeOthers(tab.id) }
            .disabled(group.tabs.count < 2)
        Divider()
        Button(tab.isPinned ? String(localized: "取消固定") : String(localized: "固定")) { workbench.dock.togglePinned(tab.id) }
        Button("向右拆分") {
            workbench.dock.drop(tab.id, onGroup: group.id, zone: .right)
            workbench.syncSelectionFromDock()
        }
        .disabled(group.tabs.count < 2)
        Button(workbench.dock.maximizedGroupID == group.id ? String(localized: "还原布局") : String(localized: "最大化此组")) { workbench.dock.toggleMaximize(group: group.id) }
        if case .file(let path) = tab.kind {
            Divider()
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
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
        case .chat(let id), .changes(let id), .history(let id, _): return (id as NSString).abbreviatingWithTildeInPath
        case .subagent: return String(localized: "子 Agent 会话")
        case .terminal, .agentTerminal: return String(localized: "终端")
        case .preview: return String(localized: "预览")
        }
    }

    private var filtered: [Item] {
        let key = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(key) || $0.subtitle.localizedCaseInsensitiveContains(key) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("全部标签")
                Text("\(group.tabs.count)")
                    .font(OMFonts.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
                Text("点击切换 · 悬停关闭").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            }
            .font(OMFonts.small.weight(.medium))
            .foregroundStyle(OMColors.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if group.tabs.count >= Self.searchThreshold {
                HStack(spacing: 6) {
                    Image.om("search", size: 12).foregroundStyle(OMColors.tertiaryText)
                    TextField("搜索标签名称或路径…", text: $filter)
                        .textFieldStyle(.plain)
                        .font(OMFonts.small)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider()
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    if filtered.isEmpty {
                        Text("未找到匹配的标签")
                            .font(OMFonts.small)
                            .foregroundStyle(OMColors.tertiaryText)
                            .padding(.vertical, 20)
                    }
                    ForEach(filtered) { item in
                        TabOverflowRow(workbench: workbench, item: item, isActive: item.tab.id == group.activeID, dismiss: dismiss)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 350)
    }
}

/// 下拉中的一行:图标 + 标题(含同名序号)+ 路径摘要;右侧运行/未保存点,悬停时出现关闭按钮。
private struct TabOverflowRow: View {
    let workbench: WorkbenchModel
    let item: TabOverflowList.Item
    let isActive: Bool
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 16, height: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(OMFonts.small.weight(isActive ? .semibold : .regular))
                        .lineLimit(1)
                    if let duplicate = item.duplicate {
                        Text("#\(duplicate)")
                            .font(OMFonts.caption.monospacedDigit())
                            .foregroundStyle(OMColors.secondaryText)
                            .padding(.horizontal, 4)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
                    }
                    if item.tab.isDirty { Circle().fill(OMColors.warning).frame(width: 6, height: 6).help("有未保存修改") }
                    if case .chat(let projectID) = item.tab.kind, let uid = workbench.sessions[projectID]?.uid {
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
            .help("关闭标签")
            .accessibilityLabel("关闭标签")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.primary.opacity(0.07) : (hovering ? Color.primary.opacity(0.045) : Color.clear))
        )
        .overlay(alignment: .leading) {
            if isActive { Capsule().fill(OMColors.accent).frame(width: 3).padding(.vertical, 8).padding(.leading, 2) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            workbench.activateTab(item.tab.id)
            dismiss()
        }
        .background(MiddleClickCatcher { if !item.tab.isPinned { AppActions.shared.requestCloseTab(item.tab.id) } })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
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
