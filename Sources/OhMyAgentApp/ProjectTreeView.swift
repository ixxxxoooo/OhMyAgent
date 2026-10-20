// @author ixxxxoooo
// 左栏(对齐 kuku 的 Sidebar):顶部 35pt 标题区(红绿灯与侧栏开关浮层) → 主操作(新对话/搜索/自定义)
// → 「置顶」「工作区」两个分区 → 底部设置。分区标题行右侧放筛选菜单与添加工作区;
// 分组标题:文件夹图标 + 名称 + 会话数(悬停换成「+」);会话行:状态点 + 渐隐标题 + 固定 44pt 保留区(相对时间 ⇄ 置顶/归档)。

import ACPKit
import ChatKit
import DesignSystem
import IconKit
import OMLog
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchKit

/// 侧栏中的一行会话(由当前会话与历史缓存合并而来)。
struct SidebarSession: Identifiable, Equatable {
    var id: String { "\(projectID)#\(sessionId ?? uid ?? "new")" }
    let projectID: String
    /// 协议会话 ID;尚未产生消息的新对话为 nil(不可置顶/归档)
    let sessionId: String?
    let uid: String?
    let title: String
    let updatedAt: Date?
    let isCurrent: Bool
    let isRunning: Bool
    /// 会话所属 Agent;只在属于「别的引擎」时才有值(点击时据此切回原引擎打开;界面不显示引擎名)
    var foreignAgentID: String?
}

extension WorkbenchModel {
    /// 项目的全部会话行:**只读持久化缓存**(`ProjectEntry.sessions`),按「创建时间」倒序,
    /// 与当前引擎、连接状态、引擎历史刷新都无关——切换引擎、点击会话、会话有新活动时顺序都不跳动。
    /// 当前会话若是尚未产生内容的空白对话,只在该项目被选中时显示为顶部的「新对话」。
    @MainActor
    func sidebarSessions(for project: ProjectEntry) -> [SidebarSession] {
        let model = sessions[project.id]
        // 该项目下所有已打开的会话(含尚无内容的空白新对话):点了「新对话」就是真实存在的会话,不随选中项目变化而消失
        let openModels = conversations.filter { $0.key.projectID == project.id }.map(\.value)
        // 只有存在已打开会话时才需要按 ID 查缓存条目(避免为 400 条缓存会话白建字典)
        let cache = openModels.isEmpty ? [:] : Dictionary(project.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        let currentAgent = model?.descriptor.id
        let deleted = Set(project.deletedSessions)
        let openIDs = Set(openModels.compactMap(\.sessionId))
        var rows: [(key: Date, row: SidebarSession)] = project.sessions.compactMap { item in
            guard !openIDs.contains(item.sessionId), !EmptySessionRegistry.isHidden(item.sessionId), !deleted.contains(item.sessionId) else { return nil }
            let displayDate = Self.parseDate(item.updatedAt) ?? Self.parseDate(item.createdAt) ?? Self.parseDate(item.firstSeenAt)
            return (item.stableKey, SidebarSession(
                projectID: project.id, sessionId: item.sessionId, uid: nil,
                title: item.title ?? String(localized: "未命名对话"),
                updatedAt: displayDate, isCurrent: false, isRunning: false,
                foreignAgentID: item.agentId.flatMap { $0 != currentAgent ? $0 : nil }
            ))
        }
        for open in openModels where !deleted.contains(open.sessionId ?? "") {
            let cached = open.sessionId.flatMap { cache[$0] }
            let key = cached?.stableKey ?? .distantFuture
            rows.append((key, SidebarSession(
                projectID: project.id, sessionId: open.sessionId, uid: open.uid,
                title: open.sessionTitle ?? cached?.title ?? String(localized: "新对话"),
                updatedAt: nil, isCurrent: open === model, isRunning: open.isRunning
            )))
        }
        // 稳定排序:创建时间倒序(新对话 .distantFuture 排在最前);同键按原始相对顺序全序兜底
        return rows.enumerated().sorted { lhs, rhs in
            if lhs.element.key != rhs.element.key {
                return lhs.element.key > rhs.element.key
            }
            return lhs.offset < rhs.offset
        }.map(\.element.row)
    }
}

/// 左栏根视图。
struct ProjectTreeView: View {
    @Bindable var workbench: WorkbenchModel
    @State private var showArchived = false

    /// 所有项目中已置顶的会话。
    private var pinned: [SidebarSession] {
        // 只有登记了置顶会话的项目才需要构造完整会话行(其余项目由各自的 ProjectGroup 构造),避免每次 body 对全部项目重复排序
        workbench.projects.filter { !$0.pinnedSessions.isEmpty }.flatMap { project in
            workbench.sidebarSessions(for: project).filter { item in
                guard let id = item.sessionId else { return false }
                return project.pinnedSessions.contains(id)
            }
        }
    }

    var body: some View {
        let _ = PanelToggleProbe.count("tree")
        VStack(spacing: 0) {
            // 顶部 35pt:红绿灯与侧栏开关浮层所在区域,可拖动窗口
            Color.clear.frame(height: TitlebarMetrics.height).background(WindowDragArea())
            navigation
            ScrollView {
                // 行数有限(每项目最多预览 5 条),用普通 VStack:LazyVStack 在悬停/选中重排时按估算高度布局,会让整列抖动
                VStack(alignment: .leading, spacing: 2) {
                    if !pinned.isEmpty {
                        SectionTitle(title: "置顶")
                        ForEach(pinned) { item in
                            SessionLine(workbench: workbench, item: item, mode: .pinned)
                        }
                    }
                    generalSection
                    SectionTitle(title: "工作区") {
                        if !workbench.workspaceProjects.isEmpty {
                            let collapsed = workbench.allProjectsCollapsed
                            SectionIconButton(
                                icon: collapsed ? "chevrons-up-down" : "chevrons-down-up",
                                label: collapsed ? String(localized: "展开全部项目") : String(localized: "折叠全部项目")
                            ) { workbench.setAllProjectsCollapsed(!collapsed) }
                        }
                        filterMenu
                        addProjectMenu
                    }
                    // 「工作区」标题行同时是拖动手柄:拖到窗口左/右半边即可把项目栏换到那一侧
                    .terminalDragHandle(workbench, panel: .sidebar)
                    if workbench.workspaceProjects.isEmpty {
                        Text("添加一个项目目录,或把文件夹拖到这里。")
                            .font(OMFonts.small)
                            .foregroundStyle(OMColors.tertiaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    ForEach(workbench.orderedProjects) { project in
                        ProjectGroup(workbench: workbench, project: project, showArchived: showArchived)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            footer
        }
        .dropDestination(for: URL.self) { urls, _ in
            var added = false
            for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                added = workbench.openProject(url) != nil || added
            }
            return added
        }
    }

    // MARK: 会话区

    /// 会话区:不绑定项目的通用对话(ChatGPT 式问答),位于「工作区」之上。
    @ViewBuilder
    private var generalSection: some View {
        SectionTitle(title: "会话") {
            SectionIconButton(icon: "message-circle-plus", label: String(localized: "新会话(无需项目)")) { workbench.newGeneralConversation() }
        }
        GeneralSessionList(workbench: workbench, showArchived: showArchived)
    }

    // MARK: 顶部主操作

    /// 主操作区:新对话、自动化、自定义(MCP/技能/插件等的合并页);搜索入口在标题栏的搜索图标与 ⌘K。
    private var navigation: some View {
        VStack(spacing: 2) {
            // 选中项目时在该项目下新对话;没有项目或停在会话区时开一个不绑定项目的通用对话
            NavRow(title: "新对话", icon: "square.and.pencil", shortcut: ShortcutStore.shared.binding(for: .newConversation).display) {
                workbench.newConversationInContext()
            }
            NavRow(title: "自动化", icon: "workflow", shortcut: nil) { workbench.openAutomation() }
            NavRow(title: "自定义", icon: "sliders-horizontal", shortcut: nil) { workbench.openCustomize() }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// 分区标题行里的筛选菜单(显示已归档会话)。
    private var filterMenu: some View {
        Menu {
            Toggle("显示已归档会话", isOn: $showArchived)
        } label: {
            Image.om("sliders-horizontal", size: 12)
                .frame(width: 22, height: 22)
                .foregroundStyle(showArchived ? OMColors.accent : OMColors.tertiaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .omTooltip("筛选")
        .accessibilityLabel("筛选")
    }

    /// 「添加项目」菜单:最近项目 / 打开文件夹 / 新建文件夹。
    private var addProjectMenu: some View {
        let opened = Set(workbench.workspaceProjects.map(\.id))
        let recents = RecentStore.projects().filter { !opened.contains($0) }.prefix(6)
        return Menu {
            if !recents.isEmpty {
                Section("最近项目") {
                    ForEach(Array(recents), id: \.self) { path in
                        Button { AppActions.shared.openWorkspace(URL(fileURLWithPath: path)) } label: {
                            Text(verbatim: (path as NSString).lastPathComponent)
                        }
                    }
                }
            }
            Section {
                Button("打开文件夹…") {
                    if let url = WorkspaceStore.chooseDirectory() { AppActions.shared.openWorkspace(url) }
                }
                Button("新建文件夹…") {
                    if let url = WorkspaceStore.createFolder() { AppActions.shared.openWorkspace(url) }
                }
            }
        } label: {
            Image.om("folder.badge.plus", size: 12)
                .frame(width: 22, height: 22)
                .foregroundStyle(OMColors.tertiaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .omTooltip("添加项目…")
        .accessibilityLabel("添加项目…")
    }

    // MARK: 底部

    /// 底部只保留设置图标(对齐 kuku)。
    private var footer: some View {
        HStack {
            Button { AppActions.shared.openSettings() } label: {
                Image.om("gearshape", size: 14)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(OMColors.secondaryText)
            .omTooltip("设置 (⌘,)")
            .accessibilityLabel("设置")
            if DemoLaunch.isActive { DemoBadgeView(workbench: workbench) } else if AppEnv.isDev() { DevBadgeView() }
            Spacer()
            UpdateFooterButton()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// 分区标题行:小号三级文字,右侧可放操作图标。
private struct SectionTitle<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
            Spacer(minLength: 0)
            trailing
        }
        .font(OMFonts.caption.weight(.medium))
        .foregroundStyle(OMColors.tertiaryText)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .padding(.top, 2)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(title: LocalizedStringKey) {
        self.init(title: title) { EmptyView() }
    }
}

/// 分区标题行里的小图标按钮。
private struct SectionIconButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image.om(icon, size: 12)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .omTooltip(label)
        .accessibilityLabel(label)
    }
}

/// 主操作行:图标 + 文案 + 可选快捷键提示(rounded-lg,hover 底色)。
private struct NavRow: View {
    let title: LocalizedStringKey
    let icon: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image.om(icon, size: 14).opacity(0.7).frame(width: 16)
                Text(title).font(OMFonts.small)
                Spacer()
                if let shortcut { Text(shortcut).font(OMFonts.caption).monospacedDigit().foregroundStyle(OMColors.tertiaryText) }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).fill(hovering ? OMColors.hoverFill : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 会话区的会话列表:每次最多预览 5 条,其余走「显示更多」;置顶的会话在顶部「置顶」分区。
private struct GeneralSessionList: View {
    private static let previewCount = 5

    let workbench: WorkbenchModel
    let showArchived: Bool
    @State private var showAll = false

    private var rows: [SidebarSession] {
        guard let entry = workbench.projects.first(where: \.isChatArea) else { return [] }
        return workbench.sidebarSessions(for: entry).filter { item in
            guard let id = item.sessionId else { return true }
            if entry.pinnedSessions.contains(id) { return false }
            return showArchived || !entry.archivedSessions.contains(id)
        }
    }

    /// 列表里排在 `item` 之后、已有会话 ID 的行(用于「归档下方全部」)。
    static func idsBelow(_ item: SidebarSession, in all: [SidebarSession]) -> [String] {
        guard let index = all.firstIndex(where: { $0.id == item.id }) else { return [] }
        return all[(index + 1)...].compactMap(\.sessionId)
    }

    var body: some View {
        let all = rows
        let visible = showAll ? all : Array(all.prefix(Self.previewCount))
        VStack(alignment: .leading, spacing: 2) {
            if all.isEmpty {
                Text("还没有会话,直接提问即可")
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            ForEach(visible) { item in
                SessionLine(workbench: workbench, item: item, mode: .general, below: Self.idsBelow(item, in: all))
            }
            if all.count > Self.previewCount {
                Button(showAll ? String(localized: "收起") : String(localized: "显示更多(还有 \(all.count - Self.previewCount) 条)")) {
                    omWithAnimation(.snappy(duration: 0.18)) { showAll.toggle() }
                }
                .buttonStyle(.plain)
                .font(OMFonts.small)
                .foregroundStyle(OMColors.secondaryText)
                .padding(.leading, 8)
                .padding(.vertical, 4)
            }
        }
    }
}

/// 工作区分组:标题行(文件夹图标 + 名称 + 会话数/悬停「+」,点击折叠)+ 会话行。
private struct ProjectGroup: View {
    /// 每个分组默认展示的会话条数,超出走「显示更多」
    private static let previewCount = 5

    let workbench: WorkbenchModel
    let project: ProjectEntry
    let showArchived: Bool
    @State private var hovering = false
    @State private var showAll = false

    private var isSelected: Bool { workbench.selectedProjectID == project.id }
    private var expanded: Bool { !project.collapsed }

    /// 本项目要在树中展示的会话(排除置顶,按开关决定是否含已归档)。
    private var rows: [SidebarSession] {
        workbench.sidebarSessions(for: project).filter { item in
            if let id = item.sessionId {
                if project.pinnedSessions.contains(id) { return false }
                if project.archivedSessions.contains(id) && !showArchived { return false }
            }
            return true
        }
    }

    var body: some View {
        let all = rows
        VStack(alignment: .leading, spacing: 2) {
            header(count: all.count)
            if expanded {
                if all.isEmpty {
                    Text("暂无会话")
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.tertiaryText)
                        .padding(.leading, 16)
                        .padding(.vertical, 4)
                }
                let visible = showAll ? all : Array(all.prefix(Self.previewCount))
                ForEach(visible) { item in
                    SessionLine(workbench: workbench, item: item, mode: .tree, below: GeneralSessionList.idsBelow(item, in: all))
                }
                if all.count > Self.previewCount {
                    Button(showAll ? String(localized: "收起") : String(localized: "显示更多(还有 \(all.count - Self.previewCount) 条)")) {
                        omWithAnimation(.snappy(duration: 0.18)) { showAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            ProjectIconView(icon: project.icon, directory: workbench.projectIconDirectory, expanded: expanded, isSelected: isSelected)
            Text(project.name)
                .font(OMFonts.small.weight(.medium))
                .foregroundStyle(OMColors.secondaryText)
                .lineLimit(1)
            if let link = project.worktree {
                Image.om("git-fork", size: 11).foregroundStyle(OMColors.accentText)
                    .omTooltip(String(localized: "Git 工作树 · \(link.branch)"))
                    .accessibilityLabel("Git 工作树 \(link.branch)")
            }
            if project.pinned {
                Image.om("pin.fill", size: 9).foregroundStyle(OMColors.tertiaryText)
            }
            if project.isMultiRoot {
                Text(verbatim: "+\(project.extraFolders.count)")
                    .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                    .omTooltip(String(localized: "工作区另含 \(project.extraFolders.count) 个文件夹"))
                    .accessibilityLabel("工作区另含 \(project.extraFolders.count) 个文件夹")
            }
            Spacer(minLength: 4)
            // 固定 24pt 保留区:会话数 ⇄ 悬停「+」,互换不位移
            ZStack(alignment: .trailing) {
                Text("\(count)")
                    .font(OMFonts.caption)
                    .monospacedDigit()
                    .foregroundStyle(OMColors.tertiaryText)
                    .opacity(hovering ? 0 : 1)
                Button { workbench.newConversation(in: project.id) } label: {
                    Image.om("plus", size: 12)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .opacity(hovering ? 1 : 0)
                .omTooltip(String(localized: "在 \(project.name) 下新对话"))
                .accessibilityLabel("在 \(project.name) 下新对话")
            }
            .frame(width: 24)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(hovering ? OMColors.hoverFill : Color.clear, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
        .transaction { $0.animation = nil }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { omWithAnimation(.snappy(duration: 0.18)) { workbench.toggleCollapsed(project.id) } }
        .omTooltip((project.id as NSString).abbreviatingWithTildeInPath)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(project.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("新对话")) { workbench.newConversation(in: project.id) }
        .omContextMenu {
            OMMenuItem("新对话", icon: "message-square-plus") { workbench.newConversation(in: project.id) }
            OMMenuItem("选中此项目", icon: "folder-open") { workbench.select(project: project.id) }
            OMMenuDivider()
            OMMenuItem(verbatim: project.pinned ? String(localized: "取消置顶") : String(localized: "置顶"), icon: "pin") { workbench.togglePin(project.id) }
            OMMenuItem("更换图标…", icon: "image") { ProjectIconPicker.present(project: project, workbench: workbench) }
            OMMenuItem("重命名项目…", icon: "pencil") {
                guard let name = ExplorerActions.prompt(title: String(localized: "重命名项目"), message: String(localized: "只修改侧栏里的显示名,不会改动磁盘上的目录名。"), initial: project.name) else { return }
                workbench.renameProject(project.id, to: name)
            }
            OMMenuItem("编辑工作区…", icon: "folder-plus") { WorkspaceEditor.present(project: project, workbench: workbench) }
            OMMenuItem("在 Finder 中显示", icon: "folder-search") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            let ides = IDELauncher.installed
            if !ides.isEmpty {
                OMMenuSubmenu("在 IDE 中打开", icon: "external-link") {
                    for ide in ides {
                        OMMenuItem(verbatim: ide.name) { IDELauncher.open(project.url, with: ide) }
                    }
                }
            }
            OMMenuItem("拷贝路径", icon: "copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.id, forType: .string)
            }
            OMMenuDivider()
            OMMenuItem("全部标为已读", icon: "circle-check") { AttentionCenter.shared.markAllRead(inWorkspace: project.id) }
            OMMenuItem("归档全部会话", icon: "archive") { workbench.archiveAllSessions(in: project.id) }
            OMMenuDivider()
            OMMenuItem("移除项目", icon: "trash", isDestructive: true) { workbench.removeProject(project.id) }
        }
    }
}

/// 侧栏相对时间文案缓存:`Date.formatted(.relative)` 每次都会新建格式化器(约百微秒),
/// 展开侧栏时几十行同时计算会拖慢首帧;文案按「分钟」粒度变化,故以 (时间点, 当前分钟) 为键缓存。
@MainActor
enum SidebarRelativeTime {
    private static var cache: [String: String] = [:]

    /// - Parameters:
    ///   - date: 会话更新时间
    ///   - now: 当前时间(测试可注入)
    /// - Returns: 例如「5 分钟前」
    static func text(for date: Date, now: Date = .now) -> String {
        let key = "\(Int(date.timeIntervalSince1970))#\(Int(now.timeIntervalSince1970) / 60)"
        if let cached = cache[key] { return cached }
        let text = date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
        if cache.count > 2000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = text
        return text
    }

    /// 紧凑展示文案:去掉「前」/「ago」后缀,侧栏右侧保留区可以更窄(对齐 Cursor 的「9h」)。
    /// - Parameter text: `text(for:now:)` 的结果
    /// - Returns: 例如「5 分钟」「3d」
    static func compact(_ text: String) -> String {
        var result = text
        for suffix in ["前", " ago", "ago"] where result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
            break
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// 会话行:状态点 + 渐隐标题 + 固定 76pt 保留区(相对时间 ⇄ 悬停时的置顶/归档按钮),对齐 kuku 的 SessionRow。
private struct SessionLine: View {
    enum Mode { case tree, pinned, general }
    let workbench: WorkbenchModel
    let item: SidebarSession
    let mode: Mode
    /// 列表中排在本行下方的会话 ID(用于「归档下方全部」)
    var below: [String] = []
    @State private var hovering = false

    private var isSelected: Bool { item.isCurrent && workbench.selectedProjectID == item.projectID }
    private var isPinned: Bool { item.sessionId.map { workbench.isSessionPinned($0, in: item.projectID) } ?? false }
    private var isArchived: Bool { item.sessionId.map { workbench.isSessionArchived($0, in: item.projectID) } ?? false }
    private var projectName: String { workbench.projects.first { $0.id == item.projectID }?.name ?? "" }

    var body: some View {
        HStack(spacing: 8) {
            SessionStatusDot(uid: item.isCurrent ? item.uid : nil, isRunning: item.isRunning)
                .frame(width: 10, height: 10)
            // 标题溢出时右端渐隐(不用省略号硬截断);短标题不受影响
            Text(item.title)
                .font(OMFonts.small)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isArchived ? OMColors.tertiaryText : OMColors.primaryText)
                .flowingText(item.isRunning)
                // minWidth: 0 允许收缩到小于文字自然宽度(否则长标题会把整行撑出侧栏)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                // 渐隐用背景色渐变覆盖层(不用 .mask:避免每行离屏渲染);底色 = 侧栏背景 + 当前行状态填充
                .omFadeTrailingEdge(width: 24, base: OMColors.sidebar, fill: isSelected ? OMColors.selectedFill : (hovering ? OMColors.hoverFill : nil))
            trailing
                .frame(width: 44, height: 20, alignment: .trailing)
        }
        .padding(.leading, mode == .tree ? 16 : 8)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous)
                .fill(isSelected ? OMColors.selectedFill : (hovering ? OMColors.hoverFill : Color.clear))
        )
        // 悬停时仅普通填充,不再叠加高光扫过的流动效果
        .transaction { $0.animation = nil }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        // 可拖进编辑区:边缘分屏、中心并入标签组、标签栏插入位置
        .onDrag {
            DockDrag.shared.beginSession(item)
            return NSItemProvider(object: (DockDrag.sessionPrefix + item.id) as NSString)
        }
        .omTooltip(mode == .pinned ? "\(projectName) · \(item.title)" : item.title)
        .omContextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var trailing: some View {
        if hovering, let id = item.sessionId {
            HStack(spacing: 2) {
                if !isArchived {
                    rowAction(icon: isPinned ? "pin.fill" : "pin", label: isPinned ? String(localized: "取消置顶") : String(localized: "置顶")) {
                        workbench.toggleSessionPin(id, in: item.projectID)
                    }
                }
                rowAction(icon: "archivebox", label: isArchived ? String(localized: "取消归档") : String(localized: "归档")) {
                    workbench.setSessionArchived(!isArchived, sessionId: id, in: item.projectID)
                }
            }
        } else if let date = item.updatedAt {
            HStack(spacing: 4) {
                if isPinned { Image.om("pin.fill", size: 9) }
                Text(SidebarRelativeTime.compact(SidebarRelativeTime.text(for: date)))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(OMFonts.caption)
            .foregroundStyle(OMColors.tertiaryText)
        } else if isPinned {
            Image.om("pin.fill", size: 9).foregroundStyle(OMColors.tertiaryText)
        }
    }

    private func rowAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image.om(icon, size: 12)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(OMColors.tertiaryText)
        .omTooltip(label)
        .accessibilityLabel(label)
    }

    @OMMenuBuilder
    private var menu: [MenuEntry] {
        OMMenuItem("打开", icon: "external-link", action: open)
        if let id = item.sessionId {
            OMMenuItem(verbatim: isPinned ? String(localized: "取消置顶") : String(localized: "置顶"), icon: "pin") { workbench.toggleSessionPin(id, in: item.projectID) }
            OMMenuItem("重命名…", icon: "pencil") { rename(id) }
            if isSelected, let model = workbench.sessions[item.projectID] {
                OMMenuItem("分支", icon: "git-branch") { _ = workbench.forkConversation(from: model) }
            }
            OMMenuSubmenu("拷贝", icon: "copy") {
                OMMenuItem("会话 ID") { copy(id) }
                OMMenuItem("标题") { copy(item.title) }
            }
            OMMenuDivider()
            OMMenuItem(verbatim: isArchived ? String(localized: "取消归档") : String(localized: "归档"), icon: isArchived ? "archive-restore" : "archive") {
                workbench.setSessionArchived(!isArchived, sessionId: id, in: item.projectID)
            }
            if !below.isEmpty {
                OMMenuItem("归档下方全部", icon: "archive") { workbench.archiveSessions(below, in: item.projectID) }
            }
            OMMenuDivider()
            OMMenuItem("删除", icon: "trash", isDestructive: true) {
                AppActions.shared.deleteSession(projectID: item.projectID, sessionId: id, title: item.title, agentID: item.foreignAgentID)
            }
        }
    }

    /// 弹出输入框重命名会话。
    private func rename(_ id: String) {
        guard let name = ExplorerActions.prompt(title: String(localized: "重命名会话"), initial: item.title) else { return }
        workbench.renameSession(id, in: item.projectID, to: name)
    }

    /// 写入剪贴板。
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func open() {
        if item.isCurrent {
            workbench.select(project: item.projectID)
        } else if let id = item.sessionId {
            workbench.openHistory(project: item.projectID, sessionId: id, title: item.title, agentID: item.foreignAgentID)
        }
    }
}

/// 行首状态点:运行中实心点呼吸 / 等待处理空心环呼吸 / 未读完成静止小点 / 常态灰点(历史会话与空闲)。
/// 颜色一律取主题强调色,呼吸动画遵循「减弱动态效果」。
private struct SessionStatusDot: View {
    /// 当前会话的 uid(历史会话为 nil,只显示灰点)
    let uid: String?
    let isRunning: Bool
    private let center = AttentionCenter.shared

    var body: some View {
        let state = uid.flatMap { center.items[$0]?.state } ?? (isRunning ? .running : .idle)
        switch state {
        case .running:
            OMSessionDot(.running, size: 7).accessibilityLabel("运行中")
        case .needsInput:
            OMSessionDot(.waiting, size: 8).accessibilityLabel("等待处理")
        case .unreadDone:
            OMSessionDot(.unread, size: 7).accessibilityLabel("已完成,未读")
        case .idle:
            OMSessionDot(.idle, size: 6)
        }
    }
}

/// 会话状态点(标签条用):运行中实心呼吸、待处理空心环呼吸、未读完成静止点;已读/空闲不显示。
struct AttentionDot: View {
    let uid: String
    private let center = AttentionCenter.shared

    var body: some View {
        switch center.items[uid]?.state ?? .idle {
        case .idle:
            EmptyView()
        case .unreadDone:
            OMSessionDot(.unread, size: 8).accessibilityLabel("已完成,未读")
        case .running:
            OMSessionDot(.running, size: 8).accessibilityLabel("运行中")
        case .needsInput:
            OMSessionDot(.waiting, size: 8).accessibilityLabel("等待处理")
        }
    }
}
