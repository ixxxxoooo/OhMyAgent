// @author ixxxxoooo
// IDE 编辑器组的标签栏:文件图标 + 标题(预览标签斜体)+ 脏点/关闭按钮 + 固定图钉;
// 单击激活、双击固定(转为非预览)、中键关闭、右键菜单、拖动重排或拖到别的组;放不下时可横向滚动。

import ChatKit
import DesignSystem
import IconKit
import IDEKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchKit

/// 标签栏尺寸常量。
enum IDETabMetrics {
    static let height: CGFloat = 32
    static let maxLabelWidth: CGFloat = 180
}

/// 拖动标签用的字符串协议:`oma-tab:<uuid>`。
enum IDETabTransfer {
    static let prefix = "oma-tab:"

    /// 把标签标识编码为拖动字符串。
    static func encode(_ id: UUID) -> String { prefix + id.uuidString }

    /// 解码拖动字符串;格式不符返回 nil。
    static func decode(_ text: String) -> UUID? {
        guard text.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(prefix.count)))
    }
}

struct IDETabBar: View {
    let workspace: IDEWorkspace
    let group: TabGroup
    let isFocused: Bool
    @State private var isDropTargeted = false
    /// 标签总宽(用于算出标签之后空白区的宽度)
    @State private var tabsWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            tabsStrip
            actions
        }
        .frame(height: IDETabMetrics.height)
        .background(OMColors.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(OMColors.hairline).frame(height: 1) }
        .overlay { if isDropTargeted { Rectangle().strokeBorder(OMColors.accent, lineWidth: 1) } }
        .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
            Self.loadTabID(from: providers) { id in
                var layout = workspace.model.editor
                layout.move(id, toGroup: group.id)
                workspace.model.editor = layout
            }
        }
    }

    /// 标签栏右侧:拆分编辑器、更多操作(同 VS Code)。
    private var actions: some View {
        HStack(spacing: 2) {
            actionButton("columns-2", String(localized: "向右拆分编辑器")) { workspace.splitGroup(group.id, zone: .right) }
            actionButton("ellipsis", String(localized: "更多操作")) { showMore() }
        }
        .padding(.horizontal, 6)
        .disabled(group.active == nil)
    }

    private func actionButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 14).foregroundStyle(OMColors.secondaryText) }
            .buttonStyle(.omIcon)
            .omTooltip(title)
            .accessibilityLabel(title)
    }

    /// 在点击处弹出「更多操作」菜单。
    private func showMore() {
        guard let event = NSApp.currentEvent, let window = event.window else { return }
        let groupID = group.id
        let workspace = workspace
        let entries = OMMenuItem("向右拆分", icon: "columns-2") { workspace.splitGroup(groupID, zone: .right) }.menuEntries
            + OMMenuItem("向下拆分", icon: "rows-2") { workspace.splitGroup(groupID, zone: .bottom) }.menuEntries
            + OMMenuDivider().menuEntries
            + OMMenuItem("关闭已保存", icon: "x") { workspace.closeSavedTabs(in: groupID) }.menuEntries
            + OMMenuItem("关闭全部", icon: "x") { workspace.closeAllTabs(in: groupID) }.menuEntries
        OMContextMenuCenter.shared.present(entries: entries, in: window, at: window.convertPoint(toScreen: event.locationInWindow))
    }

    private var tabsStrip: some View {
        GeometryReader { geo in ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(group.tabs) { tab in
                            IDETabItem(workspace: workspace, tab: tab, isActive: tab.id == group.activeID, groupFocused: isFocused, groupID: group.id)
                                .id(tab.id)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
                    // 标签之后的空白区:双击新建文件(同 VS Code 标签栏空白处双击新建)。
                    // 水平 ScrollView 里 `maxWidth: .infinity` 拿不到剩余宽度,这里按「栏宽 − 标签总宽」显式撑满
                    Color.clear.frame(width: max(24, geo.size.width - tabsWidth), height: IDETabMetrics.height)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if let root = workspace.root { workspace.create(in: root, isDirectory: false) } }
                }
            }
            .onChange(of: group.activeID) { _, id in
                guard let id else { return }
                withAnimation(OMMotion.standard) { proxy.scrollTo(id) }
            }
        } }
    }

    /// 从拖放内容里异步取出标签标识。
    @discardableResult
    static func loadTabID(from providers: [NSItemProvider], _ handler: @escaping @MainActor (UUID) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = IDETabTransfer.decode(text) else { return }
            Task { @MainActor in handler(id) }
        }
        return true
    }
}

/// 单个标签。
private struct IDETabItem: View {
    let workspace: IDEWorkspace
    let tab: WorkbenchTab
    let isActive: Bool
    let groupFocused: Bool
    let groupID: UUID
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(tab.title)
                .font(OMFonts.small)
                .italic(tab.isPreview)
                .foregroundStyle(isActive ? OMColors.primaryText : OMColors.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: IDETabMetrics.maxLabelWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: IDETabMetrics.height)
        .background(isActive ? OMColors.contentBackground : (hovering ? OMColors.hoverFill : Color.clear))
        .overlay(alignment: .top) {
            if isActive { Rectangle().fill(groupFocused ? OMColors.accent : OMColors.hairline).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(OMColors.hairline).frame(width: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { activate() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { keepOpen() })
        .background(MiddleClickCatcher { workspace.requestClose(tab.id) })
        .onDrag { NSItemProvider(object: IDETabTransfer.encode(tab.id) as NSString) }
        .omContextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        if case .file = tab.kind { OMFileIcon(name: tab.title, size: 14) }
        else { Image.om("file-text", size: 14).foregroundStyle(OMColors.secondaryText) }
    }

    /// 右侧:脏点(悬停时变关闭按钮)/ 关闭按钮 / 图钉。
    @ViewBuilder
    private var trailing: some View {
        if tab.isPinned {
            Image.om("pin", size: 12).foregroundStyle(OMColors.secondaryText).frame(width: 16, height: 16)
        } else if tab.isDirty && !hovering {
            Circle().fill(OMColors.secondaryText).frame(width: 8, height: 8).frame(width: 16, height: 16)
        } else {
            Button { workspace.requestClose(tab.id) } label: { Image.om("x", size: 12) }
                .buttonStyle(.omIcon)
                .opacity(isActive || hovering ? 1 : 0)
                .frame(width: 16, height: 16)
                .omTooltip(String(localized: "关闭"))
                .accessibilityLabel(String(localized: "关闭"))
        }
    }

    private func activate() {
        var layout = workspace.model.editor
        layout.focus(group: groupID)
        layout.activate(tab.id)
        workspace.model.editor = layout
    }

    private func keepOpen() {
        var layout = workspace.model.editor
        layout.keepOpen(tab.id)
        workspace.model.editor = layout
    }

    private var menu: [MenuEntry] {
        let id = tab.id
        var items: [MenuEntry] = []
        items += OMMenuItem("关闭", icon: "x", shortcut: "⌘W") { workspace.requestClose(id, force: true) }.menuEntries
        items += OMMenuItem("关闭其他", icon: "x") { workspace.requestCloseOthers(id) }.menuEntries
        items += OMMenuItem(tab.isPinned ? "取消固定" : "固定标签", icon: "pin") {
            var layout = workspace.model.editor
            layout.togglePinned(id)
            workspace.model.editor = layout
        }.menuEntries
        if case .file(let path) = tab.kind {
            items += OMMenuDivider().menuEntries
            items += OMMenuItem("拆分到右侧", icon: "columns-2") {
                var layout = workspace.model.editor
                layout.drop(id, onGroup: groupID, zone: .right)
                workspace.model.editor = layout
            }.menuEntries
            items += OMMenuItem("在文件树中显示", icon: "folder-search") { workspace.reveal(path) }.menuEntries
            items += OMMenuItem("在 Finder 中显示", icon: "folder-open") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.menuEntries
            items += OMMenuItem("拷贝路径", icon: "copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }.menuEntries
        }
        return items
    }
}
