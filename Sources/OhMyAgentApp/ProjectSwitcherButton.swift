// @author ixxxxoooo
// 输入区左上角的当前项目切换按钮与弹层(参考 Cursor):
// 显示当前工作区名称,点击展开项目列表,支持搜索、新建项目、快速启动与无项目会话。

import AppKit
import ChatKit
import DesignSystem
import IconKit
import OMLog
import SwiftUI
import WorkbenchKit

/// 项目切换列表条目。
struct ProjectPickItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isCurrent: Bool
    let icon: String
}

/// 项目列表处理纯逻辑(可单测)。
enum ProjectSwitcherListing {
    /// 组合工作台项目与最近项目(去重并排除会话区目录)。
    static func items(
        workspaceProjects: [ProjectEntry],
        recentPaths: [String],
        currentWorkspace: URL,
        isChatArea: Bool,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [ProjectPickItem] {
        var result: [ProjectPickItem] = []
        var seen = Set<String>()
        let currentStandardized = currentWorkspace.standardizedFileURL.path

        for project in workspaceProjects where !project.isChatArea {
            let path = project.url.standardizedFileURL.path
            seen.insert(path)
            let isCurrent = !isChatArea && path == currentStandardized
            result.append(ProjectPickItem(id: project.id, name: project.name, isCurrent: isCurrent, icon: "folder"))
        }

        for path in recentPaths {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard !seen.contains(standardized), fileExists(standardized) else { continue }
            seen.insert(standardized)
            let name = (path as NSString).lastPathComponent
            let isCurrent = !isChatArea && standardized == currentStandardized
            result.append(ProjectPickItem(id: standardized, name: name, isCurrent: isCurrent, icon: "folder"))
        }

        return result
    }

    /// 根据查询词过滤项目列表。
    static func filter(_ items: [ProjectPickItem], query: String) -> [ProjectPickItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        let scored = items.compactMap { item -> (ProjectPickItem, Int)? in
            guard let score = PickListMatcher.score(query: trimmed, in: item.name) else { return nil }
            return (item, score)
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

/// 输入区左上角的项目切换按钮。
struct ProjectSwitcherButton: View {
    let model: SessionModel
    let workbench: WorkbenchModel
    @State private var shown = false
    @State private var hovering = false

    private var isChatArea: Bool {
        workbench.isChatAreaWorkspace(model.workspace)
    }

    private var currentTitle: String {
        if isChatArea {
            return String(localized: "无项目")
        }
        if let project = workbench.projects.first(where: { $0.url.standardizedFileURL.path == model.workspace.standardizedFileURL.path }) {
            return project.name
        }
        let name = model.workspace.lastPathComponent
        return name.isEmpty ? String(localized: "无项目") : name
    }

    private var currentIcon: String {
        isChatArea ? "square-slash" : "folder"
    }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            HStack(spacing: 4) {
                Image.om(currentIcon, size: 12)
                    .foregroundStyle(OMColors.secondaryText)
                Text(currentTitle)
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
                    .lineLimit(1)
                Image.om("chevron-down", size: 9)
                    .foregroundStyle(OMColors.secondaryText)
                    .opacity(hovering || shown ? 0.9 : 0.5)
            }
            .font(OMFonts.caption)
            .padding(.horizontal, 6)
            .frame(height: 22)
            // 对齐分支切换 chip 的样式:平时无背景,悬停/展开才显示胶囊填充
            .background(OMPillShape().fill(hovering || shown ? OMColors.hoverFill : Color.clear))
            .contentShape(OMPillShape())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .omTooltip(String(localized: "切换项目"))
        .accessibilityLabel(String(localized: "当前项目: \(currentTitle)"))
        .omCustomPicker(isPresented: $shown, placement: .below, width: 220) {
            ProjectPickerPopover(model: model, workbench: workbench, shown: $shown)
        }
    }
}

/// 项目选择浮层卡片。
private struct ProjectPickerPopover: View {
    let model: SessionModel
    let workbench: WorkbenchModel
    @Binding var shown: Bool

    @State private var query = ""
    @State private var highlightedID: String?
    @FocusState private var searchFocused: Bool

    private var allItems: [ProjectPickItem] {
        ProjectSwitcherListing.items(
            workspaceProjects: workbench.workspaceProjects,
            recentPaths: RecentStore.projects(),
            currentWorkspace: model.workspace,
            isChatArea: workbench.isChatAreaWorkspace(model.workspace)
        )
    }

    private var filteredProjects: [ProjectPickItem] {
        ProjectSwitcherListing.filter(allItems, query: query)
    }

    private var navigableIDs: [String] {
        var ids = filteredProjects.map(\.id)
        ids.append("action:openFolder")
        ids.append("action:newProject")
        ids.append("action:quickStart")
        ids.append("action:noProject")
        return ids
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            projectList
            Divider()
            actionsSection
            Divider()
            noProjectSection
        }
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.escape) { shown = false; return .handled }
        .onKeyPress(.return) { confirmSelection(); return .handled }
        .task {
            initHighlight()
            try? await Task.sleep(for: .milliseconds(40))
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            highlightFirst()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image.om("search", size: 12)
                .foregroundStyle(OMColors.tertiaryText)
            TextField(String(localized: "搜索项目"), text: $query)
                .textFieldStyle(.plain)
                .font(OMFonts.small)
                .focused($searchFocused)
                .onSubmit { confirmSelection() }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var projectList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredProjects) { project in
                        projectRow(project)
                            .id(project.id)
                    }
                    if filteredProjects.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(String(localized: "没有匹配的项目"))
                            .font(OMFonts.caption)
                            .foregroundStyle(OMColors.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlightedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func projectRow(_ project: ProjectPickItem) -> some View {
        let isHighlighted = highlightedID == project.id
        return HStack(spacing: 7) {
            Image.om("folder", size: 14)
                .foregroundStyle(OMColors.secondaryText)
            Text(project.name)
                .font(OMFonts.small)
                .lineLimit(1)
            Spacer(minLength: 4)
            if project.isCurrent {
                Image.om("check", size: 12)
                    .foregroundStyle(OMColors.accent)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            isHighlighted ? OMColors.pressedFill : Color.clear,
            in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous)
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { highlightedID = project.id }
        }
        .onTapGesture {
            selectProject(project.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            actionRow(
                id: "action:openFolder",
                icon: "folder-open",
                title: String(localized: "打开文件夹"),
                isChecked: false
            ) {
                shown = false
                if let url = WorkspaceStore.chooseDirectory() {
                    AppActions.shared.openWorkspace(url)
                }
            }

            actionRow(
                id: "action:newProject",
                icon: "folder-plus",
                title: String(localized: "新建项目"),
                isChecked: false
            ) {
                shown = false
                if let url = WorkspaceStore.chooseDirectory() {
                    AppActions.shared.openWorkspace(url)
                }
            }

            actionRow(
                id: "action:quickStart",
                icon: "folder-symlink",
                title: String(localized: "快速启动"),
                isChecked: false
            ) {
                shown = false
                if let url = WorkspaceStore.createQuickStartDirectory() {
                    AppActions.shared.openWorkspace(url)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var noProjectSection: some View {
        actionRow(
            id: "action:noProject",
            icon: "square-slash",
            title: String(localized: "无项目"),
            isChecked: workbench.isChatAreaWorkspace(model.workspace)
        ) {
            shown = false
            workbench.newGeneralConversation()
        }
        .padding(.vertical, 3)
    }

    private func actionRow(
        id: String,
        icon: String,
        title: String,
        isChecked: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHighlighted = highlightedID == id
        return HStack(spacing: 7) {
            Image.om(icon, size: 14)
                .foregroundStyle(OMColors.secondaryText)
            Text(title)
                .font(OMFonts.small)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isChecked {
                Image.om("check", size: 12)
                    .foregroundStyle(OMColors.accent)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            isHighlighted ? OMColors.pressedFill : Color.clear,
            in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous)
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { highlightedID = id }
        }
        .onTapGesture {
            action()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func moveHighlight(_ delta: Int) {
        let ids = navigableIDs
        guard !ids.isEmpty else { return }
        guard let current = highlightedID, let idx = ids.firstIndex(of: current) else {
            highlightedID = delta > 0 ? ids.first : ids.last
            return
        }
        let count = ids.count
        let nextIdx = (idx + delta + count) % count
        highlightedID = ids[nextIdx]
    }

    private func initHighlight() {
        if workbench.isChatAreaWorkspace(model.workspace) {
            highlightedID = "action:noProject"
        } else if let current = allItems.first(where: \.isCurrent) {
            highlightedID = current.id
        } else {
            highlightedID = navigableIDs.first
        }
    }

    private func highlightFirst() {
        highlightedID = navigableIDs.first
    }

    private func confirmSelection() {
        guard let id = highlightedID else { return }
        if id == "action:openFolder" {
            shown = false
            if let url = WorkspaceStore.chooseDirectory() {
                AppActions.shared.openWorkspace(url)
            }
        } else if id == "action:newProject" {
            shown = false
            if let url = WorkspaceStore.chooseDirectory() {
                AppActions.shared.openWorkspace(url)
            }
        } else if id == "action:quickStart" {
            shown = false
            if let url = WorkspaceStore.createQuickStartDirectory() {
                AppActions.shared.openWorkspace(url)
            }
        } else if id == "action:noProject" {
            shown = false
            workbench.newGeneralConversation()
        } else {
            selectProject(id)
        }
    }

    private func selectProject(_ path: String) {
        shown = false
        if workbench.projects.contains(where: { $0.id == path }) {
            workbench.select(project: path)
        } else {
            AppActions.shared.openWorkspace(URL(fileURLWithPath: path))
        }
    }
}
