// @author ixxxxoooo
// IDE 编辑区:按 `DockLayout` 递归渲染编辑器组与分屏;每组 = 标签栏 + 面包屑/编辑器(复用 `FileTabView`),
// 最近使用的若干标签保持挂载(`TabKeepAlive`),切换不重建;组内容区支持拖入标签做分屏/合并。

import DesignSystem
import IconKit
import IDEKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchKit

/// 编辑区根视图。
struct IDEEditorArea: View {
    let workspace: IDEWorkspace
    private var model: IDEWindowModel { workspace.model }

    var body: some View {
        let layout = model.editor
        Group {
            if layout.allTabs.isEmpty {
                IDEEditorEmptyState()
            } else if let id = layout.maximizedGroupID, let group = layout.group(id) {
                IDEEditorGroupView(workspace: workspace, group: group)
            } else {
                IDEEditorNodeView(workspace: workspace, node: layout.root)
            }
        }
        .background(OMColors.contentBackground)
    }
}

/// 空状态:显示可用快捷键提示。
struct IDEEditorEmptyState: View {
    var body: some View {
        let shortcuts = ShortcutStore.shared
        VStack(spacing: 14) {
            Image.om("code", size: 28).foregroundStyle(OMColors.tertiaryText)
            VStack(spacing: 6) {
                hint(String(localized: "显示 / 隐藏侧栏"), shortcuts.binding(for: .toggleSidebar).display)
                hint(String(localized: "显示 / 隐藏面板"), shortcuts.binding(for: .togglePanel).display)
                hint(String(localized: "显示 / 隐藏 Agent 面板"), shortcuts.binding(for: .toggleInspector).display)
                hint(String(localized: "最大化 Agent 面板"), "⌥⌘E")
                hint(String(localized: "切换到 Agents Window"), shortcuts.binding(for: .switchWindowMode).display)
                hint(String(localized: "新建 IDE 窗口"), shortcuts.binding(for: .newIDEWindow).display)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ title: String, _ keys: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                .frame(width: 160, alignment: .trailing)
            Text(keys).font(OMFonts.small).foregroundStyle(OMColors.tertiaryText)
                .frame(width: 80, alignment: .leading)
        }
    }
}

/// 递归节点。
struct IDEEditorNodeView: View {
    let workspace: IDEWorkspace
    let node: DockNode

    var body: some View {
        switch node {
        case .group(let group): IDEEditorGroupView(workspace: workspace, group: group)
        case .split(let split): IDEEditorSplitView(workspace: workspace, split: split)
        }
    }
}

/// 分屏:按比例分配,分隔条可拖;拖动中只改本地比例,松手才写回布局。
struct IDEEditorSplitView: View {
    let workspace: IDEWorkspace
    let split: DockSplit
    @State private var dragBase: [Double]?
    @State private var liveRatios: [Double]?

    private var horizontal: Bool { split.axis == .horizontal }

    var body: some View {
        GeometryReader { proxy in
            let total = horizontal ? proxy.size.width : proxy.size.height
            let usable = max(total - CGFloat(split.children.count - 1), 1)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(split.children.enumerated()), id: \.element.id) { index, child in
                    IDEEditorNodeView(workspace: workspace, node: child)
                        .frame(width: horizontal ? max(usable * ratio(index), 0) : nil,
                               height: horizontal ? nil : max(usable * ratio(index), 0))
                        .clipped()
                    if index < split.children.count - 1 { divider(after: index, usable: usable) }
                }
            }
        }
    }

    private func ratio(_ index: Int) -> Double {
        let ratios = liveRatios ?? split.ratios
        return ratios.indices.contains(index) ? ratios[index] : 1.0 / Double(max(split.children.count, 1))
    }

    private func divider(after index: Int, usable: CGFloat) -> some View {
        OMSplitHandle(
            axis: horizontal ? .vertical : .horizontal,
            onBegan: { dragBase = split.ratios },
            onChanged: { translation in
                let base = dragBase ?? split.ratios
                guard base.indices.contains(index + 1), usable > 0 else { return }
                let delta = Double(translation / usable)
                var next = base
                next[index] = base[index] + delta
                next[index + 1] = base[index + 1] - delta
                liveRatios = DockLayout.normalizedRatios(next)
            },
            onEnded: {
                dragBase = nil
                if let committed = liveRatios {
                    var layout = workspace.model.editor
                    layout.setRatios(committed, forSplit: split.id)
                    workspace.model.editor = layout
                }
                liveRatios = nil
            }
        )
        .accessibilityHidden(true)
    }
}

/// 编辑器组:标签栏 + 内容(保活的标签叠放,只显示激活的一个)+ 拖入落点覆盖层。
struct IDEEditorGroupView: View {
    let workspace: IDEWorkspace
    let group: TabGroup
    @State private var keepAlive = TabKeepAlive()
    @State private var zone: DockDropZone?
    @State private var size: CGSize = .zero

    private var isFocused: Bool { workspace.model.editor.focusedGroupID == group.id }

    var body: some View {
        VStack(spacing: 0) {
            IDETabBar(workspace: workspace, group: group, isFocused: isFocused)
            content
                .overlay { dropOverlay }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .onDrop(of: [.plainText], delegate: IDEGroupDropDelegate(workspace: workspace, groupID: group.id, size: size, zone: $zone))
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { focus() })
        .onChange(of: group.activeID, initial: true) { _, id in keepAlive.activate(id, in: group.tabs) }
        .onChange(of: group.tabs.map(\.id)) { _, _ in keepAlive.activate(group.activeID, in: group.tabs) }
    }

    private func focus() {
        guard !isFocused else { return }
        var layout = workspace.model.editor
        layout.focus(group: group.id)
        workspace.model.editor = layout
    }

    @ViewBuilder
    private var content: some View {
        let mounted = group.tabs.filter { keepAlive.order.contains($0.id) || $0.id == group.activeID }
        ZStack {
            ForEach(mounted) { tab in
                let active = tab.id == group.activeID
                tabBody(tab, active: active)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .zIndex(active ? 1 : 0)
            }
            if group.tabs.isEmpty { IDEEditorEmptyState() }
        }
    }

    @ViewBuilder
    private func tabBody(_ tab: WorkbenchTab, active: Bool) -> some View {
        switch tab.kind {
        case .chat, .subagent, .agentTerminal, .changes:
            OMEmptyState { Label(tab.title, om: "file-text") } description: { Text("该类型的标签在 IDE 窗口中暂不支持") }
        case .file(let path):
            // 文件、差异、历史、Blame、终端、预览等复用 Agent 窗口的同一套内容视图;环境值把脏标记与跳转改接到 IDE 窗口
            TabContentView(workbench: AppEnvironment.shared.workbench, tab: tab)
                .id(path)
                .environment(\.tabIsActive, active && isFocused)
                .environment(\.ideFileHost, workspace.fileHost)
        default:
            TabContentView(workbench: AppEnvironment.shared.workbench, tab: tab)
                .environment(\.tabIsActive, active && isFocused)
                .environment(\.ideFileHost, workspace.fileHost)
        }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if let zone {
            GeometryReader { proxy in
                let rect = Self.rect(for: zone, in: proxy.size)
                Rectangle().fill(OMColors.accent.opacity(0.12))
                    .overlay(Rectangle().strokeBorder(OMColors.accent, lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            .allowsHitTesting(false)
        }
    }

    /// 落点对应的高亮矩形。
    static func rect(for zone: DockDropZone, in size: CGSize) -> CGRect {
        switch zone {
        case .center: return CGRect(origin: .zero, size: size)
        case .left: return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

/// 组内容区的拖放代理:按指针位置判定落点(中心合并/四边分屏)。
struct IDEGroupDropDelegate: DropDelegate {
    let workspace: IDEWorkspace
    let groupID: UUID
    let size: CGSize
    @Binding var zone: DockDropZone?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

    func dropEntered(info: DropInfo) { zone = DockDropZone.zone(at: info.location, in: size) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = DockDropZone.zone(at: info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = DockDropZone.zone(at: info.location, in: size)
        zone = nil
        let workspace = workspace
        let groupID = groupID
        return IDETabBar.loadTabID(from: info.itemProviders(for: [.plainText])) { id in
            var layout = workspace.model.editor
            layout.drop(id, onGroup: groupID, zone: target)
            workspace.model.editor = layout
        }
    }
}
