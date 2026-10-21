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

    var body: some View {
        if let root = workspace.root {
            let git = GitStore.shared.model(for: root)
            VStack(spacing: 0) {
                toolbar(root: root)
                IDEExplorerView(
                    workspace: workspace,
                    rows: workspace.tree.rows,
                    decorations: git.decorationIndex,
                    activePath: workspace.model.activeFilePath,
                    styleRevision: styleRevision &+ Int(OMScale.ui * 100),
                    hitBox: hitBox
                )
                .omContextMenu { menu(root: root) }
            }
            .task(id: root) { workspace.configureTree() }
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
            Text((root as NSString).lastPathComponent.uppercased())
                .font(OMFonts.caption)
                .foregroundStyle(OMColors.secondaryText)
                .lineLimit(1)
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
