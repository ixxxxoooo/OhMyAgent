// @author ixxxxoooo
// Files 工作区:左侧内容区(空状态 / 内嵌编辑器)+ 右侧可收起、可拖宽的资源管理器。
// 在右侧树里单击文件会在左侧原地打开(不新增标签);双击或 ⌥ 点击仍作为独立文件标签打开。
// ← → 是 Files 内部的文件导航(`FilesNavStack`),与全局标签历史 `NavHistory` 相互独立。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 某个项目的 Files 工作区状态:当前文件与 ← → 导航栈。
@MainActor
@Observable
final class FilesWorkspaceModel {
    /// 文件导航栈
    private(set) var nav = FilesNavStack()

    /// 当前原地打开的文件;nil 表示显示空状态
    var current: String? { nav.current }

    /// 在左侧内容区打开文件。
    /// - Parameter path: 文件绝对路径
    func open(_ path: String) { nav.push(path) }

    /// 后退。
    func back() { nav.back() }

    /// 前进。
    func forward() { nav.forward() }

    /// 文件被删除或重命名后清除指向它(及其下)的记录。
    func forget(_ path: String) { nav.remove { $0 == path || $0.hasPrefix(path + "/") } }

    /// 关闭当前文件回到空状态。
    func closeCurrent() { nav.reset() }
}

/// 按项目保存 Files 工作区状态(切换标签/项目再回来仍停在原文件)。
@MainActor
final class FilesWorkspaceStore {
    static let shared = FilesWorkspaceStore()

    @ObservationIgnored private var models: [String: FilesWorkspaceModel] = [:]

    /// 取得(必要时创建)项目的工作区状态。
    /// - Parameter project: 项目根路径
    func model(for project: String) -> FilesWorkspaceModel {
        if let model = models[project] { return model }
        let model = FilesWorkspaceModel()
        models[project] = model
        return model
    }

    /// 文件被移到中栏后,关掉各工作区里正显示它的原地预览(回到空状态)。
    /// - Parameter path: 已在中栏打开的文件路径
    func closeIfCurrent(_ path: String) {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for model in models.values {
            guard let current = model.current else { continue }
            if current == path || URL(fileURLWithPath: current).resolvingSymlinksInPath().path == target { model.closeCurrent() }
        }
    }

    /// 所有项目的工作区都清除指向某路径的记录。
    /// - Parameter path: 被删除或重命名的文件/目录路径
    func forget(_ path: String) {
        for model in models.values { model.forget(path) }
    }

    /// 标签对应的「当前文件」:文件标签是它自己的路径,Files 标签是工作区里正打开的那个文件。
    /// - Parameters:
    ///   - tab: 标签
    ///   - project: 当前项目根(Files 标签按它取状态)
    /// - Returns: 文件绝对路径;没有对应文件为 nil
    func filePath(of tab: WorkbenchTab, project: String?) -> String? {
        switch tab.kind {
        case .file(let path): return path
        case .preview(let id):
            guard WorkbenchModel.toolsPane(fromTab: id) == .files, let project else { return nil }
            return models[project]?.current
        default: return nil
        }
    }
}

/// Files 标签的内容视图。
struct FilesWorkspaceView: View {
    @Bindable var workbench: WorkbenchModel
    /// 承载本视图的 Files 标签(内嵌编辑器的未保存标记写在它上面)
    let tab: WorkbenchTab
    /// 拖动分栏时的临时宽度(松手才写入布局)
    @State private var dragWidth: Double?

    /// 左侧内容区的最小宽度:树再宽也不会把它挤没
    private static let contentMinimum: Double = 240

    var body: some View {
        if let project = workbench.selectedProject {
            FilesWorkspaceBody(workbench: workbench, tab: tab, projectID: project.id, projectName: project.name,
                               extraFolders: project.extraFolders, dragWidth: $dragWidth)
                .id(project.id)
        } else {
            OMEmptyState { Label("没有项目", om: "folder", size: 28) } description: { Text("添加一个项目后,这里会显示它的文件。") }
        }
    }
}

/// 已选中项目时的工作区主体。
private struct FilesWorkspaceBody: View {
    let workbench: WorkbenchModel
    let tab: WorkbenchTab
    let projectID: String
    let projectName: String
    let extraFolders: [String]
    @Binding var dragWidth: Double?
    /// 开始拖动时的树宽度
    @State private var dragBase: Double?

    /// 通栏面包屑行的高度(与 `FileHeaderBar` 一致)
    private static let headerHeight: CGFloat = 30

    private var model: FilesWorkspaceModel { FilesWorkspaceStore.shared.model(for: projectID) }
    private var collapsed: Bool { workbench.layout.filesTreeCollapsed }

    var body: some View {
        GeometryReader { proxy in
            let range = PanelMetrics.filesTreeRange
            let cap = max(range.lowerBound, proxy.size.width - 240)
            let treeWidth = min(max(dragWidth ?? workbench.layout.filesTreeWidth, range.lowerBound), cap)
            HStack(spacing: 0) {
                leftContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !collapsed {
                    OMSplitHandle(
                        axis: .vertical,
                        onBegan: { dragBase = treeWidth },
                        onChanged: { translation in
                            // 树在右侧:向左拖(位移为负)变宽
                            let base = dragBase ?? treeWidth
                            dragWidth = min(max(base - Double(translation), range.lowerBound), cap)
                        },
                        onEnded: {
                            if let dragWidth { workbench.layout.filesTreeWidth = dragWidth }
                            dragWidth = nil
                            dragBase = nil
                        },
                        onDoubleClick: { workbench.layout.filesTreeWidth = PanelMetrics.filesTreeDefault }
                    )
                    .padding(.top, Self.headerHeight)
                    .zIndex(1)
                    .accessibilityLabel(String(localized: "调整资源管理器宽度"))
                    // 资源管理器在面包屑那一行下面,面包屑行通栏
                    ExplorerView(workbench: workbench, hooks: hooks)
                        .frame(width: treeWidth)
                        .frame(maxHeight: .infinity)
                        .padding(.top, Self.headerHeight)
                }
            }
        }
        .background(OMColors.surface)
        // 面包屑行下边框:通栏,覆盖内容区与资源管理器上方
        .overlay(alignment: .top) {
            OMColors.hairline.frame(height: 0.5).padding(.top, Self.headerHeight - 0.5).allowsHitTesting(false)
        }
        // 面包屑行右端的「收起 / 展开资源管理器」按钮:两种状态同一位置
        .overlay(alignment: .topTrailing) {
            Button { toggleTree() } label: { Image.om("list-tree", size: 13) }
                .buttonStyle(.plain).foregroundStyle(OMColors.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: Self.headerHeight)
                .omTooltip(collapsed ? "展开资源管理器" : "收起资源管理器")
                .accessibilityLabel(collapsed ? String(localized: "展开资源管理器") : String(localized: "收起资源管理器"))
        }
        // 文件被外部删除/重命名后,别让左侧停在失效路径上
        .task(id: ExplorerModel.shared.revision) {
            if let path = model.current, !FileManager.default.fileExists(atPath: path) { model.forget(path) }
        }
    }

    /// 资源管理器接管点:单击在左侧打开,高亮当前文件,顶部带「收起」按钮。
    private var hooks: ExplorerHooks {
        ExplorerHooks(
            openFile: { open($0) },
            activePath: model.current)
    }

    @ViewBuilder
    private var leftContent: some View {
        if let current = model.current {
            FileTabView(workbench: workbench, tab: tab, path: current, filesControls: controls, openInPlace: { open($0) })
                .id(current)
        } else {
            FilesEmptyState(workbench: workbench, projectID: projectID, extraFolders: extraFolders, onOpen: { open($0) })
        }
    }

    private var controls: FilesHeaderControls {
        FilesHeaderControls(
            canGoBack: model.nav.canGoBack, canGoForward: model.nav.canGoForward,
            onBack: { model.back() }, onForward: { model.forward() },
            treeCollapsed: collapsed, onToggleTree: { toggleTree() })
    }

    private func open(_ path: String) {
        model.open(path)
        RecentStore.recordFile(path)
    }

    private func toggleTree() {
        workbench.layout.filesTreeCollapsed.toggle()
    }
}

/// 没有选中文件时的空状态:搜索入口、新建文件与最近文件。
private struct FilesEmptyState: View {
    let workbench: WorkbenchModel
    let projectID: String
    let extraFolders: [String]
    let onOpen: (String) -> Void

    private var recents: [String] { RecentStore.files(under: [projectID] + extraFolders, limit: 8) }

    var body: some View {
        let recents = recents
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14) {
                searchField
                EmptyRow(icon: "file-plus", title: "新建文件") {
                    ExplorerActions.create(in: projectID, directory: false, workbench: workbench, onCreated: onOpen)
                }
                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("最近").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).padding(.horizontal, 8).padding(.bottom, 4)
                        ForEach(recents, id: \.self) { path in
                            RecentRow(path: path, root: projectID) { onOpen(path) }
                        }
                    }
                }
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 看起来像搜索框的按钮:点击打开中央搜索窗(只搜文件),选中后在本区域原地打开。
    private var searchField: some View {
        Button {
            HubModel.shared.present(.files, workbench: workbench, fileOpener: onOpen)
        } label: {
            HStack(spacing: 8) {
                Image.om("search", size: 13).foregroundStyle(OMColors.tertiaryText)
                Text("文件、文件夹…").font(OMFonts.body).foregroundStyle(OMColors.tertiaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "搜索文件或文件夹"))
    }
}

/// 空状态里的一行操作(图标 + 标题,悬停高亮)。
private struct EmptyRow: View {
    let icon: String
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image.om(icon, size: 13).foregroundStyle(OMColors.secondaryText)
                Text(title).font(OMFonts.body).foregroundStyle(OMColors.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).fill(hovering ? OMColors.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 最近文件的一行:彩色文件图标 + 文件名 + 弱化的所在目录。
private struct RecentRow: View {
    let path: String
    let root: String
    let action: () -> Void
    @State private var hovering = false

    private var name: String { (path as NSString).lastPathComponent }
    private var directory: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.hasPrefix(root + "/") ? String(parent.dropFirst(root.count + 1)) : (parent == root ? "" : parent)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                OMFileIcon(name: name, size: 14)
                Text(name).font(OMFonts.body).foregroundStyle(OMColors.primaryText).lineLimit(1)
                if !directory.isEmpty {
                    Text(directory).font(OMFonts.small).foregroundStyle(OMColors.tertiaryText).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).fill(hovering ? OMColors.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .omTooltip(path)
        .accessibilityLabel(name)
    }
}
