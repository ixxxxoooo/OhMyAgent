// @author ixxxxoooo
// 资源管理器:按需展开的文件树;单击预览、双击固定;右键菜单支持新建/重命名/移到废纸篓等。

import AppKit
import ChatKit
import DesignSystem
import GitKit
import IconKit
import OMLog
import SwiftUI
import WorkbenchKit

/// 资源管理器的外部接管点:Files 工作区用它让「单击文件」在左侧内容区原地打开,并按自己的当前文件高亮。
struct ExplorerHooks {
    /// 单击文件(不含 ⌥ 点击):为 nil 时走默认的 `workbench.openFile(preview: true)`
    var openFile: ((String) -> Void)?
    /// 高亮的文件路径:为 nil 时取当前聚焦标签的文件
    var activePath: String?
    /// 资源管理器顶部工具条右侧的附加按钮(如「收起」)
    var trailingAction: (icon: String, help: LocalizedStringKey, action: () -> Void)?
}

struct ExplorerView: View {
    let workbench: WorkbenchModel
    var hooks = ExplorerHooks()

    /// 某根目录的 Git 装饰(随状态轮询更新;非仓库时为空)
    fileprivate static func decorations(forRoot root: String) -> GitDecorationIndex {
        GitStore.shared.model(for: root).decorationIndex
    }

    var body: some View {
        if let project = workbench.selectedProject {
            ExplorerProjectView(projectID: project.id, projectName: project.name, extraFolders: project.extraFolders, workbench: workbench, hooks: hooks)
                .id(project.id)
        } else {
            OMEmptyState { Label("没有项目", om: "folder", size: 28) } description: { Text("添加一个项目后,这里会显示它的文件。") }
        }
    }
}

/// 滚动窗口:首个可见行与可见行数(只在变化时刷新挂载窗口)。
private struct ExplorerScrollWindow: Equatable {
    var first = 0
    var count = 60
}

/// 一个项目的资源管理器:顶部工具条 + 窗口化的文件树(只挂载可见行,数千行也不卡)。
private struct ExplorerProjectView: View {
    let projectID: String
    let projectName: String
    let extraFolders: [String]
    let workbench: WorkbenchModel
    let hooks: ExplorerHooks
    private let model = ExplorerModel.shared
    @State private var tree = ExplorerTree()
    @State private var window = ExplorerScrollWindow()
    /// 拖入的文件悬停在空白处(落点为项目根目录)
    @State private var rootDropTargeted = false
    /// 拖入的文件当前悬停的行
    @State private var dropRowID: String?
    @State private var probe = ExplorerScrollProbe()

    /// 固定行高:窗口化需要按行号直接换算位置
    static let rowHeight: CGFloat = 22
    /// 内容区上下内边距
    static let verticalPadding: CGFloat = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(projectName).font(OMFonts.small.weight(.medium)).lineLimit(1)
                Spacer()
                toolButton("file-plus", "新建文件") { ExplorerActions.create(in: projectID, directory: false, workbench: workbench) }
                toolButton("folder-plus", "新建文件夹") { ExplorerActions.create(in: projectID, directory: true, workbench: workbench) }
                toolButton("chevrons-down-up", "折叠全部文件夹") { model.collapseAll() }
                toolButton("refresh-cw", "刷新") { model.bump(); WorkspaceIndexModel.shared.refresh(root: projectID) }
                if let trailing = hooks.trailingAction { toolButton(trailing.icon, trailing.help, action: trailing.action) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            ScrollView {
                treeRows
            }
            .onScrollGeometryChange(for: ExplorerScrollWindow.self) { geometry in
                let metrics = ExplorerFlatten.viewport(offset: Double(geometry.contentOffset.y) - Double(Self.verticalPadding),
                                                       viewport: Double(geometry.containerSize.height), rowHeight: Double(Self.rowHeight))
                return ExplorerScrollWindow(first: metrics.first, count: metrics.count)
            } action: { _, new in
                window = new
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                probe.offset = new
            }
            // 统一放置区:文件夹行 = 放进该文件夹,文件行 = 放进所在文件夹,空白处 = 项目根目录
            .onDrop(of: [.fileURL], delegate: ExplorerListDropDelegate(
                rows: { tree.rows }, scrollOffset: { probe.offset }, projectID: projectID, workbench: workbench,
                targetRowID: $dropRowID, rootTargeted: $rootDropTargeted))
            .overlay {
                if rootDropTargeted {
                    RoundedRectangle(cornerRadius: OMRadius.control).strokeBorder(OMColors.accent, lineWidth: 1.5)
                        .padding(2).allowsHitTesting(false)
                }
            }
        }
        // ⌘Z 撤销文件操作只在指针位于资源管理器内时生效,避免干扰其它区域的撤销
        .onHover { ExplorerUndoCenter.shared.pointerInside = $0 }
        .onChange(of: extraFolders, initial: true) { _, _ in tree.configure(sources) }
        .onChange(of: model.collapseRevision) { _, _ in tree.collapseAll() }
        .task(id: tree.refreshToken) { tree.refresh() }
        // 拖入的文件悬停在折叠的文件夹上片刻自动展开,便于继续往深层拖
        .task(id: dropRowID) {
            guard let id = dropRowID, let row = tree.rows.first(where: { $0.id == id }), row.entry.isDirectory, !row.isExpanded else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if dropRowID == id, !Task.isCancelled { tree.expand(row.entry.path) }
        }
    }

    private var sources: [ExplorerSource] {
        [ExplorerSource(root: projectID, showsHeader: false)] + extraFolders.map { ExplorerSource(root: $0, showsHeader: true) }
    }

    /// 只挂载可见窗口内的行,窗口外用占位高度撑出完整滚动范围。
    @ViewBuilder
    private var treeRows: some View {
        let rows = tree.rows
        let range = ExplorerFlatten.window(first: window.first, visibleCount: window.count, total: rows.count)
        let visible = rows[range]
        let decorations = Dictionary(visible.map(\.root).map { ($0, ExplorerView.decorations(forRoot: $0)) }, uniquingKeysWith: { first, _ in first })
        let activePath = activeFilePath
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: CGFloat(range.lowerBound) * Self.rowHeight)
            ForEach(visible) { item in
                ExplorerTreeRow(item: item, project: projectID, tree: tree, workbench: workbench, openFile: hooks.openFile,
                                decoration: item.isRootHeader ? nil : decorations[item.root]?.kind(for: item.entry.path),
                                isActive: !item.entry.isDirectory && activePath == item.entry.path,
                                isDropTarget: dropRowID == item.id)
            }
            Color.clear.frame(height: CGFloat(max(0, rows.count - range.upperBound)) * Self.rowHeight)
        }
        .padding(.vertical, Self.verticalPadding)
    }

    private var activeFilePath: String? {
        if let path = hooks.activePath { return path }
        if case .file(let path)? = workbench.focusedActiveTab?.kind { return path }
        return nil
    }

    private func toolButton(_ icon: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 13) }
            .buttonStyle(.plain).foregroundStyle(OMColors.secondaryText).omTooltip(help).accessibilityLabel(Text(help))
    }
}

/// 文件树中的一行(文件、文件夹或附加文件夹根):点击、拖出与右键菜单。
/// 放置(拖入)由列表层的单个放置区统一处理(见 `ExplorerListDropDelegate`),
/// 避免每行各注册一个放置区导致滚动时焦点/响应者遍历随行数暴涨。
private struct ExplorerTreeRow: View {
    let item: ExplorerRowItem
    let project: String
    let tree: ExplorerTree
    let workbench: WorkbenchModel
    /// 单击文件的外部接管(见 `ExplorerHooks.openFile`)
    let openFile: ((String) -> Void)?
    let decoration: GitDecorationKind?
    let isActive: Bool
    /// 拖入的文件正悬停在本行(放置目标高亮)
    let isDropTarget: Bool

    var body: some View {
        let entry = item.entry
        ExplorerRow(depth: item.depth, name: entry.name, isDirectory: entry.isDirectory, expanded: item.isExpanded,
                    chevron: entry.isDirectory ? (item.isExpanded ? "chevron-down" : "chevron-right") : nil,
                    isActive: isActive, decoration: decoration, isDropTarget: isDropTarget) {
            if entry.isDirectory { tree.toggle(entry.path); return }
            let optionHeld = NSEvent.modifierFlags.contains(.option)
            // 被接管时:普通单击交给外部(原地打开);⌥ 点击仍按「反向位置」独立打开
            if let openFile, !optionHeld { openFile(entry.path) }
            else { workbench.openFile(entry.path, preview: true, target: optionHeld ? workbench.oppositeTarget : .auto) }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !entry.isDirectory { workbench.openFile(entry.path, preview: false) } })
        // 拖到输入框 = 引用 @路径;拖到标签栏/内容区 = 打开;拖到资源管理器的文件夹 = 移动(附加文件夹根不可拖)
        .onDrag { item.isRootHeader ? NSItemProvider() : NSItemProvider(object: URL(fileURLWithPath: entry.path) as NSURL) }
        .omContextMenu {
            if item.isRootHeader {
                ExplorerMenu.headerEntries(folder: entry.path, project: project, workbench: workbench)
            } else {
                ExplorerMenu.entries(entry: entry, root: item.root, workbench: workbench)
            }
        }
    }
}

/// 列表层的统一放置区:按光标位置换算出落点行(文件夹 = 放进该文件夹,文件 = 放进它所在的文件夹,
/// 空白处 = 项目根目录),悬停高亮,悬停片刻由视图自动展开文件夹。
private struct ExplorerListDropDelegate: DropDelegate {
    let rows: () -> [ExplorerRowItem]
    let scrollOffset: () -> CGFloat
    let projectID: String
    let workbench: WorkbenchModel
    @Binding var targetRowID: String?
    @Binding var rootTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { clear() }

    func performDrop(info: DropInfo) -> Bool {
        let directory = target(at: info.location).directory
        clear()
        ExplorerActions.drop(info.itemProviders(for: [.fileURL]), into: directory, workbench: workbench)
        return true
    }

    private func update(_ info: DropInfo) {
        let result = target(at: info.location)
        if targetRowID != result.rowID { targetRowID = result.rowID }
        let atRoot = result.rowID == nil
        if rootTargeted != atRoot { rootTargeted = atRoot }
    }

    private func clear() {
        targetRowID = nil
        rootTargeted = false
    }

    /// 光标位置对应的落点(行 ID 为 nil 表示空白处)。
    private func target(at location: CGPoint) -> (rowID: String?, directory: String) {
        let list = rows()
        let y = Double(location.y + scrollOffset() - ExplorerProjectView.verticalPadding)
        guard y >= 0 else { return (nil, projectID) }
        let index = Int(y / Double(ExplorerProjectView.rowHeight))
        guard list.indices.contains(index) else { return (nil, projectID) }
        let entry = list[index].entry
        let directory = entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
        return (list[index].id, directory)
    }
}

/// 滚动偏移的旁路记录(不参与观察,避免滚动时重绘视图);放置区用它换算光标所在行。
@MainActor
private final class ExplorerScrollProbe {
    var offset: CGFloat = 0
}

private struct ExplorerRow: View {
    let depth: Int
    let name: String
    let isDirectory: Bool
    let expanded: Bool
    let chevron: String?
    let isActive: Bool
    /// Git 装饰(有未提交变化时文字着色并在右侧显示字母/圆点)
    let decoration: GitDecorationKind?
    /// 拖入的文件正悬停在本行(放置目标高亮)
    var isDropTarget = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Group {
                    if let chevron { Image.om(chevron, size: 10) } else { Color.clear }
                }
                .frame(width: 12)
                OMFileIcon(name: name, isDirectory: isDirectory, expanded: expanded, size: OMMetrics.fileIconList)
                Text(name).font(OMFonts.small).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(decoration.map(Self.tint) ?? OMColors.primaryText)
                Spacer(minLength: 0)
                if let decoration {
                    if isDirectory {
                        Circle().fill(Self.tint(decoration)).frame(width: 6, height: 6).accessibilityHidden(true)
                    } else {
                        Text(decoration.letter).font(OMFonts.caption.weight(.medium)).foregroundStyle(Self.tint(decoration))
                    }
                }
            }
            .padding(.leading, 8 + CGFloat(depth) * 12)
            .padding(.vertical, 3)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ExplorerProjectView.rowHeight)
            .background(RoundedRectangle(cornerRadius: OMRadius.tag).fill(isActive || isDropTarget ? OMColors.selectedFill : (hovering ? OMColors.hoverFill : .clear)).padding(.horizontal, 4))
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: OMRadius.tag).strokeBorder(OMColors.accent, lineWidth: 1).padding(.horizontal, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityValue(decoration.map(Self.accessibilityName) ?? "")
    }

    /// 装饰类型对应的颜色:修改为警示黄、新增/未跟踪为绿、删除/冲突为红。
    private static func tint(_ kind: GitDecorationKind) -> Color {
        switch kind {
        case .modified: return OMColors.warning
        case .added, .renamed, .untracked: return OMColors.success
        case .deleted, .conflict: return OMColors.danger
        }
    }

    /// 无障碍读法。
    private static func accessibilityName(_ kind: GitDecorationKind) -> String {
        switch kind {
        case .modified: return String(localized: "已修改")
        case .added: return String(localized: "已新增")
        case .renamed: return String(localized: "已重命名")
        case .untracked: return String(localized: "未跟踪")
        case .deleted: return String(localized: "已删除")
        case .conflict: return String(localized: "有冲突")
        }
    }
}

extension EnvironmentValues {
    /// 资源管理器的 Git 装饰索引
    @Entry var gitDecorations = GitDecorationIndex()
}

private extension String {
    /// 去掉末尾的指定后缀(仅一次)。
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}

private enum ExplorerMenu {
    /// 附加文件夹根节点的右键菜单。
    @OMMenuBuilder
    static func headerEntries(folder: String, project: String, workbench: WorkbenchModel) -> [MenuEntry] {
        OMMenuItem("在 Finder 中显示", icon: "folder-search") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
        OMMenuItem("从工作区移除", icon: "x", isDestructive: true) {
            workbench.removeFolder(folder, from: project)
            WorkspaceIndexModel.shared.refresh(root: project)
        }
    }

    /// 资源管理器条目的右键菜单。
    @OMMenuBuilder
    static func entries(entry: FileEntry, root: String, workbench: WorkbenchModel) -> [MenuEntry] {
        let parent = entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
        let relative = entry.path.hasPrefix(root + "/") ? String(entry.path.dropFirst(root.count + 1)) : entry.path
        if !entry.isDirectory {
            OMMenuItem("打开", icon: "file-text") { workbench.openFile(entry.path, preview: false) }
            OMMenuItem("在中栏打开", icon: "app-window") { workbench.openFile(entry.path, preview: false, target: .editor) }
            OMMenuItem("在右栏打开", icon: "panel-right") { workbench.openFile(entry.path, preview: false, target: .right) }
        }
        OMMenuItem("新建文件…", icon: "file-plus") { ExplorerActions.create(in: parent, directory: false, workbench: workbench) }
        OMMenuItem("新建文件夹…", icon: "folder-plus") { ExplorerActions.create(in: parent, directory: true, workbench: workbench) }
        OMMenuDivider()
        OMMenuItem("重命名…", icon: "pencil") { ExplorerActions.rename(entry, workbench: workbench) }
        OMMenuItem("移到废纸篓", icon: "trash", isDestructive: true) { ExplorerActions.trash(entry, workbench: workbench) }
        OMMenuDivider()
        if !entry.isDirectory {
            OMMenuItem("Git 历史", icon: "clock") { workbench.openHistory(project: root, path: entry.path) }
            OMMenuItem("Git Blame", icon: "git-fork") { workbench.openBlame(entry.path) }
            OMMenuDivider()
        }
        OMMenuItem("在 Finder 中显示", icon: "folder-open") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        OMMenuItem("拷贝路径", icon: "copy") { copy(entry.path) }
        OMMenuItem("拷贝相对路径", icon: "copy") { copy(relative) }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 资源管理器的文件操作(弹窗确认,后台执行)。
@MainActor
enum ExplorerActions {
    /// 弹出单行文本输入框(自绘模态)。
    /// - Parameters:
    ///   - title: 标题
    ///   - message: 说明
    ///   - initial: 初始文本
    ///   - validate: 校验(返回错误文案表示不合法)
    /// - Returns: 去除首尾空白后的输入;取消或为空返回 nil
    static func prompt(title: String, message: String = "", initial: String = "", validate: ((String) -> String?)? = nil) -> String? {
        OMDialog.prompt(title: title, message: message, initial: initial, validate: validate)
    }

    /// 文件名校验错误文案(合法返回 nil)。
    static func nameError(_ name: String) -> String? {
        isValidName(name) ? nil : String(localized: "名称不能包含 / 或为 . 与 ..")
    }

    /// 校验名称:不能含路径分隔符或为 `.`/`..`。
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// 新建文件或文件夹。
    /// - Parameter onCreated: 新建的是文件时的回调(Files 工作区借此原地打开);nil 时按默认方式打开标签
    static func create(in directory: String, directory isDirectory: Bool, workbench: WorkbenchModel, onCreated: ((String) -> Void)? = nil) {
        guard let name = prompt(title: isDirectory ? String(localized: "新建文件夹") : String(localized: "新建文件"), validate: nameError), isValidName(name) else { return }
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
            ExplorerUndoCenter.shared.record(FileOpGroup(title: "新建", ops: [.created(path: target)]), workbench: workbench)
            ExplorerModel.shared.bump()
            WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
            if !isDirectory { if let onCreated { onCreated(target) } else { workbench.openFile(target, preview: false) } }
        }
    }

    static func rename(_ entry: FileEntry, workbench: WorkbenchModel) {
        guard let name = prompt(title: String(localized: "重命名"), initial: entry.name, validate: nameError), isValidName(name), name != entry.name else { return }
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
            ExplorerUndoCenter.shared.record(FileOpGroup(title: "重命名", ops: [.move(from: source, to: target)]), workbench: workbench)
            // 已打开的该文件标签随之关闭,避免指向失效路径
            workbench.closeTabsInAllDocks { tab in
                if case .file(let p) = tab.kind { return p == source || p.hasPrefix(source + "/") }
                return false
            }
            // Files 工作区与「最近文件」里指向旧路径的记录一并清除
            FilesWorkspaceStore.shared.forget(source)
            RecentStore.removeFiles(at: source)
            ExplorerModel.shared.bump()
            WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
        }
    }

    static func trash(_ entry: FileEntry, workbench: WorkbenchModel) {
        guard OMDialog.confirm(title: String(localized: "要把「\(entry.name)」移到废纸篓吗?"), confirmTitle: String(localized: "移到废纸篓"), destructive: true) else { return }
        let source = entry.path
        Task {
            let result = await Task.detached { () -> (error: String?, trashed: String?) in
                do {
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: source), resultingItemURL: &resulting)
                    return (nil, resulting?.path)
                } catch { return (error.localizedDescription, nil) }
            }.value
            if let error = result.error { report(error); return }
            Log.editor.info("资源管理器移到废纸篓", ["path": source])
            if let trashed = result.trashed {
                ExplorerUndoCenter.shared.record(FileOpGroup(title: "移到废纸篓", ops: [.trashed(original: source, trashed: trashed)]), workbench: workbench)
            }
            workbench.closeTabsInAllDocks { tab in
                if case .file(let p) = tab.kind { return p == source || p.hasPrefix(source + "/") }
                return false
            }
            // Files 工作区与「最近文件」里指向旧路径的记录一并清除
            FilesWorkspaceStore.shared.forget(source)
            RecentStore.removeFiles(at: source)
            ExplorerModel.shared.bump()
            WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
        }
    }

    private static func report(_ message: String) {
        Log.ui.warning("资源管理器文件操作失败", ["error": message])
        OMDialog.alert(title: String(localized: "操作失败"), message: message, isError: true)
    }

    // MARK: 拖放

    /// 处理拖到资源管理器某文件夹上的文件:工作区内的为移动,外部(Finder 等)拖入的为复制。
    /// 同名项目先询问是否替换(被替换的移到废纸篓);有未保存修改的文件不移动。
    /// - Parameters:
    ///   - providers: 拖放内容
    ///   - directory: 落点文件夹
    ///   - workbench: 工作台
    static func drop(_ providers: [NSItemProvider], into directory: String, workbench: WorkbenchModel) {
        Task { @MainActor in
            var sources: [String] = []
            for provider in providers where provider.canLoadObject(ofClass: URL.self) {
                if let url = await loadURL(provider), url.isFileURL { sources.append(url.path) }
            }
            perform(sources: sources, into: directory, workbench: workbench)
        }
    }

    /// 执行拖放规划(见 `drop`;调试钩子 `OMA_EXPLORER_DROP` 也走这里)。
    static func perform(sources: [String], into directory: String, workbench: WorkbenchModel) {
        guard !sources.isEmpty else { return }
        let roots = workbench.selectedProject.map { [$0.id] + $0.extraFolders } ?? []
        let plan = ExplorerDropPlan.make(sources: sources, into: directory, workspaceRoots: roots)
        if !plan.rejected.isEmpty {
            report(String(localized: "不能把文件夹移到它自身或它的子文件夹里。"))
        }
        let dirty = plan.transfers.filter { transfer in
            transfer.kind == .move && FileDocumentStore.shared.dirtyDocuments.contains { $0.path == transfer.source || $0.path.hasPrefix(transfer.source + "/") }
        }
        if !dirty.isEmpty {
            report(String(localized: "「\(dirty.map { ($0.source as NSString).lastPathComponent }.joined(separator: "、"))」有未保存的修改,请先保存再移动。"))
        }
        var transfers = plan.transfers.filter { transfer in !dirty.contains(transfer) }
        let conflicts = transfers.filter { FileManager.default.fileExists(atPath: $0.destination) }
        if !conflicts.isEmpty {
            let names = conflicts.map { ($0.destination as NSString).lastPathComponent }.joined(separator: "、")
            let replace = OMDialog.confirm(title: String(localized: "目标文件夹中已有同名项目"),
                                           message: String(localized: "「\(names)」已存在。要替换吗?被替换的项目会移到废纸篓。"),
                                           confirmTitle: String(localized: "替换"), destructive: true)
            if !replace { transfers.removeAll { conflicts.contains($0) } }
        }
        guard !transfers.isEmpty else { return }
        let jobs = transfers
        Task {
            let (failures, ops) = await Task.detached { () -> ([String], [FileOp]) in
                let fm = FileManager.default
                var failures: [String] = []
                var ops: [FileOp] = []
                for job in jobs {
                    do {
                        if fm.fileExists(atPath: job.destination) {
                            var resulting: NSURL?
                            try fm.trashItem(at: URL(fileURLWithPath: job.destination), resultingItemURL: &resulting)
                            if let trashed = resulting?.path { ops.append(.trashed(original: job.destination, trashed: trashed)) }
                        }
                        switch job.kind {
                        case .move: try fm.moveItem(atPath: job.source, toPath: job.destination); ops.append(.move(from: job.source, to: job.destination))
                        case .copy: try fm.copyItem(atPath: job.source, toPath: job.destination); ops.append(.created(path: job.destination))
                        }
                    } catch {
                        failures.append("\((job.source as NSString).lastPathComponent):\(error.localizedDescription)")
                    }
                }
                return (failures, ops)
            }.value
            ExplorerUndoCenter.shared.record(FileOpGroup(title: "拖放", ops: ops), workbench: workbench)
            for job in jobs where job.kind == .move && FileManager.default.fileExists(atPath: job.destination) {
                // 已打开的标签改指新位置;旧路径的(未修改)内存文档丢弃,打开时按新路径重新读取
                workbench.retargetFilesInAllDocks(from: job.source, to: job.destination)
                for path in FileDocumentStore.shared.documents.keys where path == job.source || path.hasPrefix(job.source + "/") {
                    FileDocumentStore.shared.discard(path)
                }
            }
            Log.editor.info("资源管理器拖放", ["into": directory, "moved": "\(jobs.filter { $0.kind == .move }.count)", "copied": "\(jobs.filter { $0.kind == .copy }.count)", "failed": "\(failures.count)"])
            if !failures.isEmpty {
                Log.editor.error("资源管理器拖放部分失败", ["details": failures.joined(separator: "; ")])
                report(failures.joined(separator: "\n"))
            }
            ExplorerModel.shared.bump()
            WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
