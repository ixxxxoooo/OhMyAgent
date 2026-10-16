// @author ixxxxoooo
// 资源管理器:按需展开的文件树;单击预览、双击固定;右键菜单支持新建/重命名/移到废纸篓等。

import AppKit
import DesignSystem
import IconKit
import OMLog
import SwiftUI
import WorkbenchKit

struct ExplorerView: View {
    let workbench: WorkbenchModel
    private let model = ExplorerModel.shared

    var body: some View {
        if let project = workbench.selectedProject {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(project.name).font(OMFonts.small.weight(.semibold)).lineLimit(1)
                    Spacer()
                    toolButton("file-plus", "新建文件") { ExplorerActions.create(in: project.id, directory: false, workbench: workbench) }
                    toolButton("folder-plus", "新建文件夹") { ExplorerActions.create(in: project.id, directory: true, workbench: workbench) }
                    toolButton("chevrons-down-up", "折叠全部文件夹") { model.collapseAll() }
                    toolButton("refresh-cw", "刷新") { model.bump(); WorkspaceIndexModel.shared.refresh(root: project.id) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        DirectoryChildren(path: project.id, depth: 0, workbench: workbench, root: project.id)
                    }
                    .padding(.vertical, 4)
                }
            }
        } else {
            ContentUnavailableView { Label("没有项目", om: "folder", size: 28) } description: { Text("添加一个项目后,这里会显示它的文件。") }
        }
    }

    private func toolButton(_ icon: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 13) }
            .buttonStyle(.plain).foregroundStyle(OMColors.secondaryText).help(help).accessibilityLabel(Text(help))
    }
}

/// 某目录的子项(进入视图时后台列举;文件操作后随刷新信号重新列举)。
private struct DirectoryChildren: View {
    let path: String
    let depth: Int
    let workbench: WorkbenchModel
    let root: String
    @State private var entries: [FileEntry] = []
    private let model = ExplorerModel.shared

    var body: some View {
        // 用 VStack 承载 task:空的 ForEach 本身没有视图,修饰符不会生效
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                if entry.isDirectory {
                    FolderRow(entry: entry, depth: depth, workbench: workbench, root: root)
                } else {
                    FileRow(entry: entry, depth: depth, workbench: workbench, root: root)
                }
            }
        }
        .task(id: "\(path)#\(model.revision)") {
            let target = path
            entries = await Task.detached(priority: .userInitiated) { WorkspaceFiles.list(directory: target) }.value
        }
    }
}

private struct FolderRow: View {
    let entry: FileEntry
    let depth: Int
    let workbench: WorkbenchModel
    let root: String
    @State private var expanded = false
    private let model = ExplorerModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExplorerRow(depth: depth, name: entry.name, isDirectory: true, expanded: expanded, chevron: expanded ? "chevron-down" : "chevron-right", isActive: false) {
                expanded.toggle()
            }
            .contextMenu { ExplorerMenu(entry: entry, root: root, workbench: workbench) }
            if expanded {
                DirectoryChildren(path: entry.path, depth: depth + 1, workbench: workbench, root: root)
            }
        }
        .onChange(of: model.collapseRevision) { _, _ in expanded = false }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    let depth: Int
    let workbench: WorkbenchModel
    let root: String

    var body: some View {
        let active = isActive
        ExplorerRow(depth: depth, name: entry.name, isDirectory: false, expanded: false, chevron: nil, isActive: active) {
            workbench.openFile(entry.path, preview: true)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { workbench.openFile(entry.path, preview: false) })
        .contextMenu { ExplorerMenu(entry: entry, root: root, workbench: workbench) }
    }

    private var isActive: Bool {
        if case .file(let p)? = workbench.dock.focusedGroup?.active?.kind { return p == entry.path }
        return false
    }
}

private struct ExplorerRow: View {
    let depth: Int
    let name: String
    let isDirectory: Bool
    let expanded: Bool
    let chevron: String?
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Group {
                    if let chevron { Image.om(chevron, size: 10) } else { Color.clear }
                }
                .frame(width: 12)
                OMFileIcon(name: name, isDirectory: isDirectory, expanded: expanded, size: 16)
                Text(name).font(OMFonts.small).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8 + CGFloat(depth) * 12)
            .padding(.vertical, 3)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(isActive ? OMColors.accent.opacity(0.18) : (hovering ? Color.primary.opacity(0.06) : .clear)).padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ExplorerMenu: View {
    let entry: FileEntry
    let root: String
    let workbench: WorkbenchModel

    var body: some View {
        if !entry.isDirectory {
            Button("打开") { workbench.openFile(entry.path, preview: false) }
        }
        Button("新建文件…") { ExplorerActions.create(in: entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent, directory: false, workbench: workbench) }
        Button("新建文件夹…") { ExplorerActions.create(in: entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent, directory: true, workbench: workbench) }
        Divider()
        Button("重命名…") { ExplorerActions.rename(entry, workbench: workbench) }
        Button("移到废纸篓") { ExplorerActions.trash(entry, workbench: workbench) }
        Divider()
        if !entry.isDirectory {
            Button("Git 历史") { workbench.openHistory(project: root, path: entry.path) }
            Button("Git Blame") { workbench.openBlame(entry.path) }
            Divider()
        }
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        Button("拷贝路径") { copy(entry.path) }
        Button("拷贝相对路径") { copy(relative) }
    }

    private var relative: String {
        entry.path.hasPrefix(root + "/") ? String(entry.path.dropFirst(root.count + 1)) : entry.path
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 资源管理器的文件操作(弹窗确认,后台执行)。
@MainActor
enum ExplorerActions {
    /// 弹出单行文本输入框。
    static func prompt(title: String, message: String = "", initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "好"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// 校验名称:不能含路径分隔符或为 `.`/`..`。
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    static func create(in directory: String, directory isDirectory: Bool, workbench: WorkbenchModel) {
        guard let name = prompt(title: isDirectory ? String(localized: "新建文件夹") : String(localized: "新建文件")), isValidName(name) else { return }
        let target = (directory as NSString).appendingPathComponent(name)
        Task {
            let error = await Task.detached { () -> String? in
                let fm = FileManager.default
                guard !fm.fileExists(atPath: target) else { return String(localized: "已存在同名项目") }
                do {
                    if isDirectory { try fm.createDirectory(atPath: target, withIntermediateDirectories: true) }
                    else { try Data().write(to: URL(fileURLWithPath: target)) }
                    return nil
                } catch { return error.localizedDescription }
            }.value
            if let error { report(error); return }
            Log.editor.info("资源管理器新建", ["path": target, "dir": "\(isDirectory)"])
            ExplorerModel.shared.bump()
            WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
            if !isDirectory { workbench.openFile(target, preview: false) }
        }
    }

    static func rename(_ entry: FileEntry, workbench: WorkbenchModel) {
        guard let name = prompt(title: String(localized: "重命名"), initial: entry.name), isValidName(name), name != entry.name else { return }
        let target = ((entry.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        let source = entry.path
        Task {
            let error = await Task.detached { () -> String? in
                guard !FileManager.default.fileExists(atPath: target) else { return String(localized: "已存在同名项目") }
                do { try FileManager.default.moveItem(atPath: source, toPath: target); return nil }
                catch { return error.localizedDescription }
            }.value
            if let error { report(error); return }
            Log.editor.info("资源管理器重命名", ["from": source, "to": target])
            // 已打开的该文件标签随之关闭,避免指向失效路径
            workbench.dock.closeTabs { tab in
                if case .file(let p) = tab.kind { return p == source || p.hasPrefix(source + "/") }
                return false
            }
            ExplorerModel.shared.bump()
            WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
        }
    }

    static func trash(_ entry: FileEntry, workbench: WorkbenchModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "要把「\(entry.name)」移到废纸篓吗?")
        alert.addButton(withTitle: String(localized: "移到废纸篓"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let source = entry.path
        Task {
            let error = await Task.detached { () -> String? in
                do { try FileManager.default.trashItem(at: URL(fileURLWithPath: source), resultingItemURL: nil); return nil }
                catch { return error.localizedDescription }
            }.value
            if let error { report(error); return }
            Log.editor.info("资源管理器移到废纸篓", ["path": source])
            workbench.dock.closeTabs { tab in
                if case .file(let p) = tab.kind { return p == source || p.hasPrefix(source + "/") }
                return false
            }
            ExplorerModel.shared.bump()
            WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
        }
    }

    private static func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "操作失败")
        alert.informativeText = message
        alert.runModal()
    }
}
