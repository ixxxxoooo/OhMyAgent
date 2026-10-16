// @author ixxxxoooo
// 左栏(对齐 kuku 的 Sidebar):顶部 35pt 标题区(红绿灯与侧栏开关浮层) → 主操作(新对话/搜索/自定义)
// → 「置顶」「工作区」两个分区 → 底部设置。分区标题行右侧放筛选菜单与添加工作区;
// 分组标题:文件夹图标 + 名称 + 会话数(悬停换成「+」);会话行:状态点 + 渐隐标题 + 固定 76pt 保留区(相对时间 ⇄ 置顶/归档)。

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
    /// 项目的全部会话行(对齐 kuku:按「首次出现时间」倒序,会话有新活动时顺序不跳动;
    /// 尚未产生消息的新对话没有协议会话 ID,固定排在最前)。
    @MainActor
    func sidebarSessions(for project: ProjectEntry) -> [SidebarSession] {
        let model = sessions[project.id]
        let cache = Dictionary(project.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        let source: [CachedSession] = {
            if let live = model?.history, !live.isEmpty {
                return live.map { CachedSession(sessionId: $0.sessionId, title: $0.title, updatedAt: $0.updatedAt, firstSeenAt: cache[$0.sessionId]?.firstSeenAt) }
            }
            return project.sessions
        }()
        var rows: [(key: Date, row: SidebarSession)] = source.compactMap { item in
            guard item.sessionId != model?.sessionId else { return nil }
            return (item.stableKey, SidebarSession(
                projectID: project.id, sessionId: item.sessionId, uid: nil,
                title: item.title ?? String(localized: "未命名对话"),
                updatedAt: Self.parseDate(item.updatedAt), isCurrent: false, isRunning: false
            ))
        }
        if let model, selectedProjectID == project.id || model.sessionId != nil || model.isRunning {
            let key = model.sessionId.flatMap { cache[$0]?.stableKey } ?? .distantFuture
            rows.append((key, SidebarSession(
                projectID: project.id, sessionId: model.sessionId, uid: model.uid,
                title: model.sessionTitle ?? String(localized: "新对话"),
                updatedAt: nil, isCurrent: true, isRunning: model.isRunning
            )))
        }
        // 稳定排序:键倒序,同键按会话 ID 兜底(全序)
        return rows.sorted { lhs, rhs in
            lhs.key != rhs.key ? lhs.key > rhs.key : (lhs.row.sessionId ?? "") < (rhs.row.sessionId ?? "")
        }.map(\.row)
    }
}

/// 左栏根视图。
struct ProjectTreeView: View {
    @Bindable var workbench: WorkbenchModel
    @State private var showArchived = false

    /// 所有项目中已置顶的会话。
    private var pinned: [SidebarSession] {
        workbench.projects.flatMap { project in
            workbench.sidebarSessions(for: project).filter { item in
                guard let id = item.sessionId else { return false }
                return project.pinnedSessions.contains(id)
            }
        }
    }

    var body: some View {
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
                    SectionTitle(title: "工作区") {
                        if !workbench.projects.isEmpty {
                            let collapsed = workbench.allProjectsCollapsed
                            SectionIconButton(
                                icon: collapsed ? "chevrons-up-down" : "chevrons-down-up",
                                label: collapsed ? String(localized: "展开全部项目") : String(localized: "折叠全部项目")
                            ) { workbench.setAllProjectsCollapsed(!collapsed) }
                        }
                        filterMenu
                        SectionIconButton(icon: "folder.badge.plus", label: String(localized: "添加项目…")) {
                            if let url = WorkspaceStore.chooseDirectory() { AppActions.shared.openWorkspace(url) }
                        }
                    }
                    ForEach(workbench.orderedProjects) { project in
                        ProjectGroup(workbench: workbench, project: project, showArchived: showArchived)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
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
    }

    // MARK: 顶部主操作

    /// 主操作区:新对话、搜索(点击展开输入框)、自定义(进入设置)。
    private var navigation: some View {
        VStack(spacing: 2) {
            NavRow(title: "新对话", icon: "square.and.pencil", shortcut: ShortcutStore.shared.binding(for: .newConversation).display) {
                if let id = workbench.selectedProjectID { workbench.newConversation(in: id) }
            }
            .disabled(workbench.selectedProjectID == nil)
            NavRow(title: "搜索", icon: "magnifyingglass", shortcut: ShortcutStore.shared.binding(for: .hubSearch).display) {
                HubModel.shared.present(.all, workbench: workbench)
            }
            NavRow(title: "自定义", icon: "slider.horizontal.3", shortcut: nil) { AppActions.shared.openSettings() }
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
        .help("筛选")
        .accessibilityLabel("筛选")
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
            .help("设置 (⌘,)")
            .accessibilityLabel("设置")
            if DemoLaunch.isActive { DemoBadgeView() }
            Spacer()
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
        .help(label)
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
                Text(title).font(OMFonts.body)
                Spacer()
                if let shortcut { Text(shortcut).font(OMFonts.caption).monospacedDigit().foregroundStyle(OMColors.tertiaryText) }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
                    SessionLine(workbench: workbench, item: item, mode: .tree)
                    if item.isCurrent { SubagentRows(workbench: workbench, projectID: project.id) }
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
            Image.om(expanded ? "folder-open" : "folder", size: 14)
                .opacity(isSelected ? 1 : 0.6)
                .foregroundStyle(isSelected ? OMColors.accent : OMColors.secondaryText)
            Text(project.name)
                .font(OMFonts.small.weight(.medium))
                .foregroundStyle(OMColors.secondaryText)
                .lineLimit(1)
            if project.pinned {
                Image.om("pin.fill", size: 9).foregroundStyle(OMColors.tertiaryText)
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
                .help("在 \(project.name) 下新对话")
                .accessibilityLabel("在 \(project.name) 下新对话")
            }
            .frame(width: 24)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .transaction { $0.animation = nil }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { omWithAnimation(.snappy(duration: 0.18)) { workbench.toggleCollapsed(project.id) } }
        .help((project.id as NSString).abbreviatingWithTildeInPath)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(project.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("新对话")) { workbench.newConversation(in: project.id) }
        .contextMenu {
            Button("新对话") { workbench.newConversation(in: project.id) }
            Button("选中此项目") { workbench.select(project: project.id) }
            Divider()
            Button(project.pinned ? String(localized: "取消置顶") : String(localized: "置顶")) { workbench.togglePin(project.id) }
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

/// 当前会话下缩进显示的子任务(子 Agent):点击在标签中打开其只读会话;运行中带活动点。
private struct SubagentRows: View {
    let workbench: WorkbenchModel
    let projectID: String

    var body: some View {
        if let model = workbench.sessions[projectID] {
            let items = model.timeline.subagentEntries()
            ForEach(Array(items.enumerated()), id: \.element.entry.id) { _, item in
                if let tool = item.entry.tool {
                    HStack(spacing: 6) {
                        Image.om("bot", size: 11).foregroundStyle(OMColors.tertiaryText).frame(width: 16)
                        Text(tool.title).font(OMFonts.caption).lineLimit(1).foregroundStyle(OMColors.secondaryText)
                        Spacer(minLength: 4)
                        if !tool.status.isTerminal {
                            Circle().fill(OMColors.accent).frame(width: 6, height: 6)
                                .accessibilityLabel("运行中")
                        }
                    }
                    .padding(.leading, CGFloat(12 + item.depth * 12))
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        workbench.openSubagent(project: projectID, toolCallID: tool.toolCallId, title: tool.title)
                    }
                    .help(tool.title)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }
}

/// 会话行:状态点 + 渐隐标题 + 固定 76pt 保留区(相对时间 ⇄ 悬停时的置顶/归档按钮),对齐 kuku 的 SessionRow。
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
        HStack(spacing: 8) {
            SessionStatusDot(uid: item.isCurrent ? item.uid : nil, isRunning: item.isRunning)
                .frame(width: 10, height: 10)
            // 标题溢出时右端渐隐(不用省略号硬截断);短标题不受影响
            Text(item.title)
                .font(OMFonts.small)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isArchived ? OMColors.tertiaryText : Color.primary)
                .flowingText(item.isRunning)
                // minWidth: 0 允许收缩到小于文字自然宽度(否则长标题会把整行撑出侧栏)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .mask(
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
                    }
                )
            trailing
                .frame(width: 76, height: 20, alignment: .trailing)
        }
        .padding(.leading, mode == .tree ? 16 : 8)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? OMColors.accent.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        // 悬停时背景上扫过一条高光(流动效果);平时不创建动画视图
        .background { if hovering { FlowSweep() } }
        .transaction { $0.animation = nil }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help(mode == .pinned ? "\(projectName) · \(item.title)" : item.title)
        .contextMenu { menu }
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
                Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
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
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var menu: some View {
        Button("打开", action: open)
        if let id = item.sessionId {
            Button(isPinned ? String(localized: "取消置顶") : String(localized: "置顶")) { workbench.toggleSessionPin(id, in: item.projectID) }
            Button(isArchived ? String(localized: "取消归档") : String(localized: "归档")) { workbench.setSessionArchived(!isArchived, sessionId: id, in: item.projectID) }
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

/// 行首状态点:运行中小转圈 / 等待处理橙点闪烁 / 未读完成绿点 / 常态灰点(历史会话与空闲)。
private struct SessionStatusDot: View {
    /// 当前会话的 uid(历史会话为 nil,只显示灰点)
    let uid: String?
    let isRunning: Bool
    private let center = AttentionCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = uid.flatMap { center.items[$0]?.state } ?? (isRunning ? .running : .idle)
        switch state {
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10).accessibilityLabel("运行中")
        case .needsInput:
            dot(.orange, blink: true).accessibilityLabel("等待处理")
        case .unreadDone:
            dot(.green, blink: false).accessibilityLabel("已完成,未读")
        case .idle:
            dot(Color.secondary.opacity(0.45), blink: false)
        }
    }

    @ViewBuilder
    private func dot(_ color: Color, blink: Bool) -> some View {
        if blink && !reduceMotion {
            Circle().fill(color).frame(width: 6, height: 6)
                .phaseAnimator([1.0, 0.3]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.7) }
        } else {
            Circle().fill(color).frame(width: 6, height: 6)
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
            Circle().fill(OMColors.success).frame(width: 8, height: 8).accessibilityLabel("已完成,未读")
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
