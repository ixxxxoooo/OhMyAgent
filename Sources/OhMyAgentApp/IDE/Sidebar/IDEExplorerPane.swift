// @author ixxxxoooo
// IDE 侧栏「资源管理器」视图:头部工具条(新建文件/文件夹、刷新、全部折叠)+ AppKit 文件树 + 自绘右键菜单。

import AppKit
import ChatKit
import DesignSystem
import GitKit
import IconKit
import IDEKit
import SwiftUI
import WorkbenchKit

struct IDEExplorerPane: View {
    let workspace: IDEWorkspace
    @State private var hitBox = IDEExplorerHitBox()
    @State private var styleRevision = 0
    /// 项目根文件夹是否展开(点击头部的项目名收起/展开整棵树,与 VS Code 一致)
    @AppStorage("ide.explorerRootExpanded") private var rootExpanded = true

    var body: some View {
        if let root = workspace.root {
            let git = GitStore.shared.model(for: root)
            VStack(spacing: 0) {
                toolbar(root: root)
                if rootExpanded {
                    IDEExplorerView(
                        workspace: workspace,
                        rows: workspace.tree.rows,
                        decorations: git.decorationIndex,
                        activePath: workspace.model.activeFilePath,
                        styleRevision: styleRevision &+ Int(OMScale.ui * 100),
                        hitBox: hitBox
                    )
                    .omContextMenu { menu(root: root) }
                } else {
                    Spacer(minLength: 0)
                }
                IDEOutlineSection(workspace: workspace)
                IDETimelineSection(workspace: workspace)
            }
            .task(id: root) { workspace.configureTree() }
            // 编辑器切换文件时,文件树自动展开并定位到它
            .onChange(of: workspace.model.activeFilePath, initial: true) { _, path in
                if let path { workspace.reveal(path) }
            }
            .task(id: workspace.tree.refreshToken) {
                workspace.tree.refresh()
                await git.refresh(full: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: ThemeRuntime.didChange)) { _ in styleRevision &+= 1 }
        }
    }

    /// 头部:工作区名 + 操作按钮(24pt 紧凑)。
    private func toolbar(root: String) -> some View {
        HStack(spacing: 2) {
            Button { rootExpanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image.om(rootExpanded ? "chevron-down" : "chevron-right", size: 12)
                    Text((root as NSString).lastPathComponent.uppercased())
                        .font(OMFonts.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(OMColors.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rootExpanded ? String(localized: "收起项目文件夹") : String(localized: "展开项目文件夹"))
            Spacer(minLength: 4)
            iconButton("file-plus", String(localized: "新建文件")) { workspace.create(in: targetDirectory(root: root), isDirectory: false) }
            iconButton("folder-plus", String(localized: "新建文件夹")) { workspace.create(in: targetDirectory(root: root), isDirectory: true) }
            iconButton("refresh-cw", String(localized: "刷新")) { ExplorerModel.shared.bump(); workspace.tree.refresh() }
            iconButton("chevrons-down-up", String(localized: "全部折叠")) { workspace.tree.collapseAll() }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func iconButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 14) }
            .buttonStyle(.omIcon)
            .omTooltip(title)
            .accessibilityLabel(title)
    }

    /// 新建的目标目录:选中的是文件夹取它;选中文件取其父目录;否则取根目录。
    private func targetDirectory(root: String) -> String {
        guard let first = workspace.selection.first else { return root }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: first, isDirectory: &isDirectory), isDirectory.boolValue { return first }
        return (first as NSString).deletingLastPathComponent
    }

    // MARK: 右键菜单

    private func menu(root: String) -> [MenuEntry] {
        let point = NSApp.currentEvent?.locationInWindow ?? .zero
        guard let item = hitBox.rowAt?(point) else {
            // 空白处:只提供新建
            return OMMenuItem("新建文件…", icon: "file-plus") { workspace.create(in: root, isDirectory: false) }.menuEntries
                + OMMenuItem("新建文件夹…", icon: "folder-plus") { workspace.create(in: root, isDirectory: true) }.menuEntries
        }
        let paths = workspace.selection.contains(item.entry.path) && workspace.selection.count > 1 ? workspace.selection : [item.entry.path]
        return Self.entries(entry: item.entry, root: root, selected: paths, workspace: workspace)
    }

    @OMMenuBuilder
    private static func entries(entry: FileEntry, root: String, selected: [String], workspace: IDEWorkspace) -> [MenuEntry] {
        let parent = entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
        let relative = entry.path.hasPrefix(root + "/") ? String(entry.path.dropFirst(root.count + 1)) : entry.path
        if !entry.isDirectory {
            OMMenuItem("打开", icon: "file-text") { workspace.open(entry.path, preview: false) }
            OMMenuItem("在侧边打开", icon: "columns-2", shortcut: "⌥ 点击") { workspace.open(entry.path, preview: false, beside: true) }
            OMMenuDivider()
        }
        OMMenuItem("新建文件…", icon: "file-plus") { workspace.create(in: parent, isDirectory: false) }
        OMMenuItem("新建文件夹…", icon: "folder-plus") { workspace.create(in: parent, isDirectory: true) }
        OMMenuDivider()
        OMMenuItem("重命名…", icon: "pencil", shortcut: "↩", isEnabled: selected.count == 1) { workspace.rename(entry.path) }
        OMMenuItem("创建副本", icon: "copy", isEnabled: selected.count == 1) { workspace.duplicate(entry.path) }
        OMMenuItem("移到废纸篓", icon: "trash", shortcut: "⌘⌫", isDestructive: true) { workspace.trash(selected) }
        OMMenuDivider()
        OMMenuItem("在 Finder 中显示", icon: "folder-open") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        OMMenuItem("拷贝路径", icon: "copy") { copy(entry.path) }
        OMMenuItem("拷贝相对路径", icon: "copy") { copy(relative) }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
