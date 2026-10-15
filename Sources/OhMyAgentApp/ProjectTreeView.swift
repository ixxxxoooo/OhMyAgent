// @author ygw
// 左栏(Cursor 风格):顶部导航(新对话/搜索/自定义)、置顶会话、项目 → 会话树、底部设置与添加项目。
// 半透明侧栏材质、紧凑行高;会话行悬停显示置顶/归档;支持搜索过滤与拖入目录添加项目。

import ACPKit
import ChatKit
import DesignSystem
import IconKit
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
}

extension WorkbenchModel {
    /// 项目的全部会话行:当前会话在前,其后为历史(按缓存顺序)。
    @MainActor
    func sidebarSessions(for project: ProjectEntry) -> [SidebarSession] {
        let model = sessions[project.id]
        var rows: [SidebarSession] = []
        if let model, selectedProjectID == project.id || model.sessionId != nil || model.isRunning {
            rows.append(SidebarSession(
                projectID: project.id, sessionId: model.sessionId, uid: model.uid,
                title: model.sessionTitle ?? String(localized: "新对话"),
                updatedAt: nil, isCurrent: true, isRunning: model.isRunning
            ))
        }
        let source: [CachedSession] = {
            if let live = model?.history, !live.isEmpty {
                return live.map { CachedSession(sessionId: $0.sessionId, title: $0.title, updatedAt: $0.updatedAt) }
            }
            return project.sessions
        }()
        for item in source where item.sessionId != model?.sessionId {
            rows.append(SidebarSession(
                projectID: project.id, sessionId: item.sessionId, uid: nil,
                title: item.title ?? String(localized: "未命名对话"),
                updatedAt: Self.parseDate(item.updatedAt), isCurrent: false, isRunning: false
            ))
        }
        return rows
    }

    /// 解析 ISO8601(含/不含毫秒)时间。
    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// 左栏根视图。
struct ProjectTreeView: View {
    @Bindable var workbench: WorkbenchModel
    @State private var query = ""
    @State private var searching = false
    @State private var showArchived = false
    @FocusState private var searchFocused: Bool

    /// 当前搜索关键字(去空白);为空表示不过滤。
    private var key: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func matches(_ item: SidebarSession) -> Bool {
        key.isEmpty || item.title.localizedCaseInsensitiveContains(key)
    }

    /// 所有项目中已置顶的会话。
    private var pinned: [SidebarSession] {
        workbench.projects.flatMap { project in
            workbench.sidebarSessions(for: project).filter { item in
                guard let id = item.sessionId else { return false }
                return project.pinnedSessions.contains(id) && matches(item)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            navigation
            List {
                if !pinned.isEmpty {
                    Section("已置顶") {
                        ForEach(pinned) { item in
                            SessionLine(workbench: workbench, item: item, mode: .pinned)
                        }
                    }
                }
                Section("项目") {
                    ForEach(workbench.orderedProjects) { project in
                        ProjectGroup(workbench: workbench, project: project, key: key, showArchived: showArchived)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 24)
            .overlay {
                if workbench.projects.isEmpty {
                    ContentUnavailableView {
                        Label("没有项目", om: "folder.badge.plus", size: 28)
                    } description: {
                        Text("添加一个项目目录,或把文件夹拖到这里。")
                    }
                }
            }
            footer
        }
        .dropDestination(for: URL.self) { urls, _ in
            var added = false
            for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                added = workbench.openProject(url) != nil || added
            }
            return added
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if width > 0 { workbench.layout.leftWidth = Double(width) }
        }
    }

    // MARK: 顶部导航

    /// 导航区:新对话、搜索(点击展开输入框)、自定义(进入设置)。
    private var navigation: some View {
        VStack(spacing: 1) {
            NavRow(title: "新对话", icon: "square.and.pencil", shortcut: ShortcutStore.shared.binding(for: .newConversation).display) {
                if let id = workbench.selectedProjectID { workbench.newConversation(in: id) }
            }
            .disabled(workbench.selectedProjectID == nil)
            if searching {
                HStack(spacing: 6) {
                    Image.om("magnifyingglass", size: 12).foregroundStyle(OMColors.tertiaryText)
                    TextField("搜索会话", text: $query)
                        .textFieldStyle(.plain)
                        .font(OMFonts.body)
                        .focused($searchFocused)
                        .onExitCommand { endSearch() }
                    Button { endSearch() } label: { Image.om("xmark.circle.fill", size: 12) }
                        .buttonStyle(.plain)
                        .foregroundStyle(OMColors.tertiaryText)
                        .accessibilityLabel("清除搜索")
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                .padding(.horizontal, 2)
            } else {
                NavRow(title: "搜索", icon: "magnifyingglass", shortcut: nil) {
                    searching = true
                    searchFocused = true
                }
            }
            NavRow(title: "自定义", icon: "slider.horizontal.3", shortcut: nil) { AppActions.shared.openSettings() }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func endSearch() {
        query = ""
        searching = false
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                if let url = WorkspaceStore.chooseDirectory() { AppActions.shared.openWorkspace(url) }
            } label: {
                Label("添加项目…", om: "folder.badge.plus").font(OMFonts.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(OMColors.secondaryText)
            Spacer()
            Button { showArchived.toggle() } label: {
                Image.om("archivebox", size: 13)
                    .foregroundStyle(showArchived ? OMColors.accent : OMColors.secondaryText)
            }
            .buttonStyle(.plain)
            .help(showArchived ? "隐藏已归档会话" : "显示已归档会话")
            .accessibilityLabel(showArchived ? "隐藏已归档会话" : "显示已归档会话")
            Button { AppActions.shared.openSettings() } label: {
                Image.om("gearshape", size: 14).foregroundStyle(OMColors.secondaryText)
            }
            .buttonStyle(.plain)
            .help("设置 (⌘,)")
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// 导航行:图标 + 文案 + 可选快捷键提示。
private struct NavRow: View {
    let title: LocalizedStringKey
    let icon: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image.om(icon, size: 13).frame(width: 16)
                Text(title).font(OMFonts.body)
                Spacer()
                if let shortcut { Text(shortcut).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText) }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 项目节点:标题行 + 会话行(置顶会话不在此重复,已归档会话按开关显示)。
private struct ProjectGroup: View {
    let workbench: WorkbenchModel
    let project: ProjectEntry
    let key: String
    let showArchived: Bool
    @State private var hovering = false
    @State private var showAll = false

    private var isSelected: Bool { workbench.selectedProjectID == project.id }

    /// 本项目要在树中展示的会话(排除置顶,按搜索过滤,按开关决定是否含已归档)。
    private var rows: [SidebarSession] {
        workbench.sidebarSessions(for: project).filter { item in
            if let id = item.sessionId {
                if project.pinnedSessions.contains(id) { return false }
                if project.archivedSessions.contains(id) && !showArchived { return false }
            }
            return key.isEmpty || item.title.localizedCaseInsensitiveContains(key)
        }
    }

    var body: some View {
        let all = rows
        if key.isEmpty || !all.isEmpty {
            DisclosureGroup(isExpanded: Binding(get: { !project.collapsed || !key.isEmpty }, set: { _ in workbench.toggleCollapsed(project.id) })) {
                let visible = showAll || !key.isEmpty ? all : Array(all.prefix(8))
                ForEach(visible) { item in
                    SessionLine(workbench: workbench, item: item, mode: .tree)
                }
                if all.count > 8 && key.isEmpty {
                    Button(showAll ? "收起" : "显示全部 \(all.count) 个会话") { showAll.toggle() }
                        .buttonStyle(.plain)
                        .font(OMFonts.caption)
                        .foregroundStyle(OMColors.secondaryText)
                }
            } label: {
                header
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image.om(isSelected ? "folder.fill" : "folder", size: 13)
                .foregroundStyle(isSelected ? OMColors.accent : OMColors.secondaryText)
            Text(project.name)
                .font(OMFonts.body.weight(.medium))
                .lineLimit(1)
            if project.pinned {
                Image.om("pin.fill", size: 9).foregroundStyle(OMColors.tertiaryText)
            }
            Spacer(minLength: 4)
            if hovering {
                Button { workbench.newConversation(in: project.id) } label: {
                    Image.om("square.and.pencil", size: 12)
                }
                .buttonStyle(.borderless)
                .help("在 \(project.name) 下新对话")
                .accessibilityLabel("在 \(project.name) 下新对话")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { workbench.select(project: project.id) }
        .help((project.id as NSString).abbreviatingWithTildeInPath)
        .contextMenu {
            Button("新对话") { workbench.newConversation(in: project.id) }
            Divider()
            Button(project.pinned ? "取消置顶" : "置顶") { workbench.togglePin(project.id) }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.id, forType: .string)
            }
            Divider()
            Button("移除项目", role: .destructive) { workbench.removeProject(project.id) }
        }
    }
}

/// 会话行:图标/状态点 + 标题 + 相对时间;悬停时时间位置换成「置顶/归档」按钮。
private struct SessionLine: View {
    enum Mode { case tree, pinned }
    let workbench: WorkbenchModel
    let item: SidebarSession
    let mode: Mode
    @State private var hovering = false

    private var isSelected: Bool { item.isCurrent && workbench.selectedProjectID == item.projectID }
    private var isPinned: Bool { item.sessionId.map { workbench.isSessionPinned($0, in: item.projectID) } ?? false }
    private var isArchived: Bool { item.sessionId.map { workbench.isSessionArchived($0, in: item.projectID) } ?? false }
    private var projectName: String { workbench.projects.first { $0.id == item.projectID }?.name ?? "" }

    var body: some View {
        HStack(spacing: 6) {
            leading
            Text(item.title)
                .font(OMFonts.body)
                .lineLimit(1)
                .foregroundStyle(isArchived ? OMColors.tertiaryText : Color.primary)
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 24)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 7).fill(OMColors.accent.opacity(0.14)) }
            else if hovering { RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help(mode == .pinned ? "\(projectName) · \(item.title)" : item.title)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leading: some View {
        if let uid = item.uid, item.isCurrent {
            ZStack {
                Image.om("bubble.left", size: 11).foregroundStyle(isSelected ? OMColors.accent : OMColors.tertiaryText)
                AttentionDot(uid: uid).offset(x: 7, y: -6)
            }
            .frame(width: 16)
        } else {
            Image.om(isPinned ? "pin.fill" : "bubble.left", size: 11)
                .foregroundStyle(OMColors.tertiaryText)
                .frame(width: 16)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if hovering, let id = item.sessionId {
            HStack(spacing: 4) {
                Button { workbench.toggleSessionPin(id, in: item.projectID) } label: {
                    Image.om(isPinned ? "pin.fill" : "pin", size: 12)
                }
                .help(isPinned ? "取消置顶" : "置顶")
                .accessibilityLabel(isPinned ? "取消置顶" : "置顶")
                Button { workbench.setSessionArchived(!isArchived, sessionId: id, in: item.projectID) } label: {
                    Image.om("archivebox", size: 12)
                }
                .help(isArchived ? "取消归档" : "归档")
                .accessibilityLabel(isArchived ? "取消归档" : "归档")
            }
            .buttonStyle(.plain)
            .foregroundStyle(OMColors.secondaryText)
        } else if item.isRunning {
            Text("工作中…").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
        } else if let date = item.updatedAt {
            Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                .font(OMFonts.caption)
                .foregroundStyle(OMColors.tertiaryText)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("打开", action: open)
        if let id = item.sessionId {
            Button(isPinned ? "取消置顶" : "置顶") { workbench.toggleSessionPin(id, in: item.projectID) }
            Button(isArchived ? "取消归档" : "归档") { workbench.setSessionArchived(!isArchived, sessionId: id, in: item.projectID) }
            if !item.isCurrent, let model = workbench.sessions[item.projectID], model.capabilities.canDelete {
                Divider()
                Button("删除", role: .destructive) {
                    model.deleteSession(SessionSummary(sessionId: id, cwd: item.projectID, title: item.title))
                }
            }
        }
    }

    private func open() {
        if item.isCurrent {
            workbench.select(project: item.projectID)
        } else if let id = item.sessionId {
            workbench.openHistory(project: item.projectID, sessionId: id, title: item.title)
        }
    }
}

/// 会话状态点:运行中蓝点闪烁、待处理橙点闪烁、未读完成绿点常亮;已读/空闲不显示。
struct AttentionDot: View {
    let uid: String
    private let center = AttentionCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch center.items[uid]?.state ?? .idle {
        case .idle:
            EmptyView()
        case .unreadDone:
            Circle().fill(Color.green).frame(width: 8, height: 8).accessibilityLabel("已完成,未读")
        case .running:
            blinking(.blue).accessibilityLabel("运行中")
        case .needsInput:
            blinking(.orange).accessibilityLabel("等待处理")
        }
    }

    @ViewBuilder
    private func blinking(_ color: Color) -> some View {
        if reduceMotion {
            Circle().fill(color).frame(width: 8, height: 8)
        } else {
            Circle().fill(color).frame(width: 8, height: 8)
                .phaseAnimator([1.0, 0.25]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.6) }
        }
    }
}
