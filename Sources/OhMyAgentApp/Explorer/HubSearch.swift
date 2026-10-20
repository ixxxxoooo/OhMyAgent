// @author ixxxxoooo
// Cursor 风格的中央搜索窗:大输入框 + 分类分段(全部/会话/项目/文件/操作/设置)+ 分组结果 + 底部快捷键提示。
// 取代旧的命令面板与侧栏内联搜索;⌘K 打开,⌘P 直达「文件」,⇧⌘P 直达「操作」。

import AppKit
import ChatKit
import DesignSystem
import IconKit
import OMLog
import SwiftUI
import WorkbenchKit

/// 中央搜索窗的视图模型。
@MainActor
@Observable
final class HubModel {
    static let shared = HubModel()

    var isPresented = false
    var query = "" {
        didSet { if query != oldValue { selection = 0; recompute() } }
    }
    var segment: HubSegment = .all {
        didSet { if segment != oldValue { selection = 0; recompute() } }
    }
    var selection = 0
    /// 每次打开搜索窗递增:视图据此把键盘焦点(重新)放进输入框,编辑器/终端占着焦点时也一样
    private(set) var focusToken = 0
    private(set) var sections: [HubSection] = []
    @ObservationIgnored private weak var workbench: WorkbenchModel?
    @ObservationIgnored private var commands: [String: PaletteCommand] = [:]
    /// 候选缓存:打开窗口时构建一次(文件索引完成后重建),输入时只做排序
    @ObservationIgnored private var candidates: [HubCandidate] = []

    /// 记录打开时的初始主题,用户取消(Escape)时回滚
    private var initialThemeID: String?
    /// 已提交的主题:搜索窗打开期间键盘预览不算数,「当前使用」标示与初始定位都以它为准
    var committedThemeID: String { initialThemeID ?? AppearanceModel.shared.themeID }
    /// 键盘监视器:打开期间处理 ↑↓ / ↵ / ⇥ / esc(底部提示里的快捷键)
    @ObservationIgnored private let keyMonitor = HubKeyMonitor()

    /// 平铺的结果(键盘选择用)。
    var flatItems: [HubItem] { sections.flatMap(\.items) }
    /// 当前选中项的 id(越界为 nil);只遍历到选中位置,不拼接整个数组。
    var selectedItemID: HubItem.ID? {
        var remaining = selection
        guard remaining >= 0 else { return nil }
        for section in sections {
            if remaining < section.items.count { return section.items[remaining].id }
            remaining -= section.items.count
        }
        return nil
    }

    /// 打开搜索窗。
    /// - Parameters:
    ///   - segment: 初始分类
    ///   - workbench: 工作台
    ///   - query: 预填查询
    func present(_ segment: HubSegment = .all, workbench: WorkbenchModel, query: String = "") {
        self.workbench = workbench
        self.segment = segment
        self.query = query
        self.initialThemeID = AppearanceModel.shared.themeID
        selection = 0
        focusToken += 1
        isPresented = true
        keyMonitor.install { [weak self] command in self?.handle(command) ?? false }
        if WorkspaceIndexModel.shared.root != workbench.selectedProjectID || WorkspaceIndexModel.shared.files.isEmpty {
            WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
        }
        rebuildCandidates()
        // 画布列表在后台读盘,读完再重建候选(避免主线程读磁盘)
        Task { [weak self] in
            await CanvasListCache.shared.refresh()
            guard let self, self.isPresented else { return }
            self.rebuildCandidates()
        }
        Log.ui.info("打开中央搜索", ["segment": segment.rawValue])
    }

    /// 直达主题切换器(VS Code 风格)
    func presentThemes(workbench: WorkbenchModel) {
        present(.themes, workbench: workbench, query: "")
    }

    /// 关闭搜索窗。
    func dismiss() {
        if let initial = initialThemeID {
            AppearanceModel.shared.themeID = initial
            initialThemeID = nil
        }
        isPresented = false
        keyMonitor.remove()
    }

    /// 执行键盘指令(由本地事件监视器调用)。
    /// - Parameter command: 解析后的指令
    /// - Returns: 是否已处理(true 时事件不再传给文本框)
    private func handle(_ command: HubKeyCommand) -> Bool {
        guard isPresented else { return false }
        switch command {
        case .move(let step): move(step)
        case .switchSegment(let step): segment = segment.next(by: step)
        case .submit: runSelected()
        case .dismiss: dismiss()
        }
        return true
    }

    /// 文件索引或工作台数据变化后重建候选。
    func rebuildCandidates() {
        guard let workbench else { return }
        let built = HubCandidateBuilder.build(workbench: workbench)
        candidates = built.candidates
        commands = built.commands
        recompute()
    }

    /// 重新排序。
    private func recompute() {
        sections = HubSearchEngine.sections(query: query, segment: segment, candidates: candidates)
        if segment == .themes && query.isEmpty {
            if let cur = flatItems.firstIndex(where: { $0.candidate.action == .theme(id: committedThemeID) }) {
                selection = cur
            } else {
                selection = 0
            }
        } else if selection >= flatItems.count {
            selection = max(flatItems.count - 1, 0)
        }
        updateLivePreview()
    }

    /// 移动选中项(循环)。
    func move(_ step: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        selection = ((selection + step) % count + count) % count
        updateLivePreview()
    }

    /// 实时预览:仅由键盘 ↑↓ 移动触发(鼠标悬浮不改变选中项,也不预览);点击才提交。
    private func updateLivePreview() {
        let items = flatItems
        guard items.indices.contains(selection) else { return }
        if case .theme(let id) = items[selection].candidate.action {
            AppearanceModel.shared.themeID = id
        } else if let initial = initialThemeID, AppearanceModel.shared.themeID != initial {
            AppearanceModel.shared.themeID = initial
        }
    }

    /// 执行当前选中项。
    func runSelected() {
        let items = flatItems
        guard items.indices.contains(selection) else { return }
        run(items[selection])
    }

    /// 执行某一项并关闭窗口。
    func run(_ item: HubItem) {
        let isTheme = if case .theme = item.candidate.action { true } else { false }
        if isTheme {
            // 用户显式选用该主题:提交并不再还原
            initialThemeID = nil
        }
        dismiss()
        guard let workbench else { return }
        switch item.candidate.action {
        case .session(let workspace, let sessionId, let title):
            AppActions.shared.openSession(workspacePath: workspace, sessionId: sessionId, title: title)
        case .project(let path):
            _ = workbench.openProject(URL(fileURLWithPath: path))
        case .file(let root, let relative):
            workbench.openFile((root as NSString).appendingPathComponent(relative), preview: false)
        case .command(let id):
            commands[id]?.run()
        case .settings(let page):
            AppActions.shared.openSettings(page: SettingsPage.resolve(page))
        case .theme(let id):
            AppearanceModel.shared.themeID = id
        case .canvas(let id, let title):
            workbench.openCanvas(id: id, title: title)
        }
    }
}

/// 候选构建:把会话、项目、文件、命令、设置页转成统一的 `HubCandidate`。
@MainActor
enum HubCandidateBuilder {
    /// 构建结果:候选与「命令 ID → 命令」表。
    static func build(workbench: WorkbenchModel) -> (candidates: [HubCandidate], commands: [String: PaletteCommand]) {
        var result: [HubCandidate] = []
        // 会话:各项目已缓存的非归档会话,按更新时间新→旧
        var sessions: [(Date, HubCandidate)] = []
        for project in workbench.projects {
            for cached in project.sessions where !project.archivedSessions.contains(cached.sessionId) && !EmptySessionRegistry.isHidden(cached.sessionId) {
                let date = HubDates.parse(cached.updatedAt ?? cached.firstSeenAt)
                let title = (cached.title?.isEmpty == false ? cached.title : nil) ?? String(localized: "新对话")
                let keywords = ["会话", "对话", "session", "chat"]
                sessions.append((date ?? .distantPast, HubCandidate(
                    id: "session:\(cached.sessionId)", segment: .sessions, title: title, subtitle: project.isChatArea ? String(localized: "会话区") : project.name,
                    trailing: date.map(HubDates.relative), icon: .symbol("message-square"), keywords: keywords,
                    action: .session(workspace: project.id, sessionId: cached.sessionId, title: cached.title))))
            }
        }
        result += sessions.sorted { $0.0 > $1.0 }.map(\.1)
        // 项目:最近打开优先
        for project in workbench.workspaceProjects.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }) {
            let keywords = ["项目", "project", "workspace", "工作区"]
            result.append(HubCandidate(
                id: "project:\(project.id)", segment: .projects, title: project.name,
                subtitle: (project.id as NSString).abbreviatingWithTildeInPath, trailing: nil,
                icon: .file(name: project.name, isDirectory: true), keywords: keywords, action: .project(path: project.id)))
        }
        // 文件:当前项目索引
        if let root = workbench.selectedProjectID, WorkspaceIndexModel.shared.root == root {
            let fileKeywords = ["文件", "file"]
            for path in WorkspaceIndexModel.shared.files {
                let name = (path as NSString).lastPathComponent
                let dir = (path as NSString).deletingLastPathComponent
                result.append(HubCandidate(
                    id: "file:\(path)", segment: .files, title: name, subtitle: dir.isEmpty ? nil : dir, trailing: nil,
                    icon: .file(name: name, isDirectory: false), searchText: path, keywords: fileKeywords, action: .file(root: root, relativePath: path)))
            }
            // 多文件夹工作区:附加文件夹的文件,副标题带上文件夹名
            for item in WorkspaceIndexModel.shared.extraFiles {
                let name = (item.path as NSString).lastPathComponent
                let folder = (item.root as NSString).lastPathComponent
                let dir = (item.path as NSString).deletingLastPathComponent
                result.append(HubCandidate(
                    id: "file:\(item.root):\(item.path)", segment: .files, title: name,
                    subtitle: dir.isEmpty ? folder : folder + "/" + dir, trailing: nil,
                    icon: .file(name: name, isDirectory: false), searchText: folder + "/" + item.path,
                    keywords: fileKeywords,
                    action: .file(root: item.root, relativePath: item.path)))
            }
        }
        // 画布:已缓存的列表(打开搜索窗时后台刷新),当前项目的优先
        let canvasKeywords = ["画布", "canvas", "报告", "图表", "report"]
        let canvasRoot = workbench.selectedProjectID
        for item in CanvasListCache.shared.items.sorted(by: { ($0.projectPath == canvasRoot ? 1 : 0, $0.updatedAt) > ($1.projectPath == canvasRoot ? 1 : 0, $1.updatedAt) }) {
            result.append(HubCandidate(
                id: "canvas:\(item.id)", segment: .canvases, title: item.title,
                subtitle: item.projectPath.map { ($0 as NSString).lastPathComponent }, trailing: HubDates.relative(item.updatedAt),
                icon: .symbol("chart-column"), keywords: canvasKeywords, action: .canvas(id: item.id, title: item.title)))
        }
        // 操作:命令面板里的全部命令
        var table: [String: PaletteCommand] = [:]
        for command in PaletteCommands.all(workbench: workbench) + DemoPaletteCommands.all(workbench: workbench) {
            table[command.id] = command
            let keywords = ["操作", "命令", "action", "command", command.id]
            result.append(HubCandidate(
                id: "action:\(command.id)", segment: .actions, title: command.title, subtitle: nil, trailing: command.shortcut,
                icon: .symbol(command.icon), keywords: keywords, action: .command(id: command.id)))
        }
        // 设置:全部设置页(含别名关键词与全局设置词)
        for group in SettingsPage.groups {
            for page in group.pages {
                let keywords = page.keywords + ["设置", "setting", "settings", "偏好设置", "preferences", group.title]
                result.append(HubCandidate(
                    id: "settings:\(page.rawValue)", segment: .settings, title: page.title, subtitle: group.title, trailing: nil,
                    icon: .symbol(page.icon), keywords: keywords, action: .settings(page: page.rawValue)))
            }
        }
        // 主题:全部预置与自定义主题
        for package in ThemePackage.all {
            let tagline = ThemePersonality.tagline(for: package)
            let tone = package.tone.displayName
            let keywords = [
                package.group.title,
                package.tone.displayName,
                "主题", "theme", "color", "配色", "外观",
                package.tone == .dark ? "深色" : (package.tone == .light ? "浅色" : "跟随系统"),
                package.tone == .dark ? "暗黑" : "明亮",
                package.id,
            ]
            result.append(HubCandidate(
                id: "theme:\(package.id)", segment: .themes, title: package.name, subtitle: tagline, trailing: tone,
                icon: .symbol("paintbrush"), keywords: keywords, action: .theme(id: package.id)))
        }
        return (result, table)
    }
}

/// 日期解析与相对时间文本。
enum HubDates {
    /// 解析 ISO8601 字符串(带或不带毫秒)。
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// 相对当前时间的短文本(如「5 分钟前」)。
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 视图

/// 中央搜索窗:覆盖在工作台之上。
struct HubOverlay: View {
    let workbench: WorkbenchModel
    @Bindable private var hub = HubModel.shared
    @FocusState private var focused: Bool

    var body: some View {
        if hub.isPresented {
            ZStack(alignment: .top) {
                // 遮罩延伸到安全区之外,把顶部标题栏/标签条一并盖住
                OMColors.scrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { hub.dismiss() }
                    .accessibilityHidden(true)
                card
                    .padding(.top, 84)
            }
            .transition(.opacity)
            .onChange(of: WorkspaceIndexModel.shared.files.count + WorkspaceIndexModel.shared.extraFiles.count) { hub.rebuildCandidates() }
            .onChange(of: workbench.projects) { hub.rebuildCandidates() }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            searchField
            segments
            Divider().opacity(0.6)
            results
            footer
        }
        .frame(width: 720)
        .omGlass(in: RoundedRectangle(cornerRadius: OMRadius.modal, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: OMRadius.modal, style: .continuous))
        .omFloatShadow(cornerRadius: OMRadius.modal)
        .onAppear { focused = true }
        .task(id: hub.focusToken) {
            // 先让当前持有焦点的编辑器/终端放手,再把焦点交给输入框;输入框出现晚一帧时补一次
            NSApp.keyWindow?.makeFirstResponder(nil)
            focused = true
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("搜索")
    }

    // MARK: 输入框

    private var searchField: some View {
        HStack(spacing: 10) {
            Image.om("search", size: 18).foregroundStyle(OMColors.secondaryText)
            TextField(searchPlaceholder, text: $hub.query)
                .textFieldStyle(.plain)
                .font(OMFonts.custom(18))
                .focused($focused)
                .onSubmit { hub.runSelected() }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var searchPlaceholder: String {
        switch hub.segment {
        case .themes: return String(localized: "搜索主题 (如 Cursor, Dracula, Tokyo, 浅色…)")
        case .files: return String(localized: "搜索文件 (如文件名或路径…)")
        case .canvases: return String(localized: "搜索画布…")
        case .actions: return String(localized: "搜索操作与快捷键…")
        case .settings: return String(localized: "搜索设置项…")
        case .sessions: return String(localized: "搜索历史会话…")
        case .projects: return String(localized: "搜索项目…")
        case .all: return String(localized: "搜索会话、项目、文件、画布、操作、设置与主题")
        }
    }

    // MARK: 分类

    private var segments: some View {
        HStack(spacing: 4) {
            ForEach(HubSegment.allCases) { item in
                Button { hub.segment = item; focused = true } label: {
                    Text(item.title)
                        .font(OMFonts.small.weight(hub.segment == item ? .medium : .regular))
                        .foregroundStyle(hub.segment == item ? OMColors.primaryText : OMColors.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(hub.segment == item ? OMColors.selectedFill : .clear, in: OMPillShape())
                        .contentShape(OMPillShape())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(hub.segment == item ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: 结果

    @ViewBuilder
    private var results: some View {
        let sections = hub.sections
        if sections.isEmpty {
            Text(emptyMessage)
                .font(OMFonts.body).foregroundStyle(OMColors.secondaryText)
                .frame(maxWidth: .infinity).frame(height: 120)
        } else {
            // 选中项 id 只算一次(原先每行都展开全部分区,O(N²))
            let selectedID = hub.selectedItemID
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            if !section.title.isEmpty {
                                Text(section.title)
                                    .font(OMFonts.caption.weight(.medium))
                                    .foregroundStyle(OMColors.tertiaryText)
                                    .padding(.horizontal, 18)
                                    .frame(height: 26, alignment: .bottom)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(section.items) { item in
                                HubRow(item: item, selected: item.id == selectedID)
                                    .id(item.id)
                                    .onTapGesture { hub.run(item) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(item.id == selectedID ? [.isButton, .isSelected] : .isButton)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(height: min(listHeight(sections), 380))
                .onChange(of: hub.selection) { _, _ in
                    if hub.flatItems.indices.contains(hub.selection) { proxy.scrollTo(hub.flatItems[hub.selection].id) }
                }
            }
        }
    }

    private var emptyMessage: String {
        if hub.segment == .themes && hub.query.isEmpty == false {
            return String(localized: "未找到匹配的主题 (支持搜索主题名、配色、深浅等)")
        }
        if hub.segment == .files || hub.segment == .all, WorkspaceIndexModel.shared.isLoading, hub.query.isEmpty == false {
            return String(localized: "正在建立文件索引…")
        }
        return hub.query.isEmpty ? String(localized: "这里还没有内容") : String(localized: "没有匹配项")
    }

    private func listHeight(_ sections: [HubSection]) -> CGFloat {
        let rowsHeight = sections.reduce(CGFloat(0)) { total, section in
            total + section.items.reduce(CGFloat(0)) { rowTotal, item in
                if case .theme = item.candidate.action { return rowTotal + 50 }
                return rowTotal + 36
            }
        }
        let headers = sections.filter { !$0.title.isEmpty }.count
        return rowsHeight + CGFloat(headers) * 26 + 8
    }

    // MARK: 底部提示

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "选择")
            hint("↵", hub.segment == .themes ? "选用主题" : "打开")
            hint("⇥", "切换分类")
            hint("esc", hub.segment == .themes ? "取消并还原" : "关闭")
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(OMColors.surface.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(OMColors.hairline.opacity(0.6)).frame(height: 0.5) }
    }

    private func hint(_ key: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(OMFonts.caption.weight(.medium))
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 16)
                .background(OMColors.hoverFill, in: RoundedRectangle(cornerRadius: OMRadius.tag))
            Text(label).font(OMFonts.caption)
        }
        .foregroundStyle(OMColors.secondaryText)
    }
}

/// 结果行。
private struct HubRow: View {
    let item: HubItem
    let selected: Bool
    /// 鼠标悬浮仅用于轻量底色提示,不影响选中项
    @State private var hovering = false

    var body: some View {
        Group {
            if case .theme(let themeID) = item.candidate.action,
               let package = ThemePackage.all.first(where: { $0.id == themeID }) {
                HubThemeRow(item: item, package: package, selected: selected, hovering: hovering)
            } else {
                standardRow
            }
        }
        .onHover { hovering = $0 }
    }

    private var standardRow: some View {
        HStack(spacing: 10) {
            icon.frame(width: 20)
            Text(titleText).font(OMFonts.body).lineLimit(1)
            if let subtitle = item.candidate.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let trailing = item.candidate.trailing {
                Text(trailing).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(selected ? OMColors.selectedFill : (hovering ? OMColors.hoverFill : .clear), in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch item.candidate.icon {
        case .symbol(let name): Image.om(name, size: 14).foregroundStyle(OMColors.secondaryText)
        case .file(let name, let isDirectory): OMFileIcon(name: name, isDirectory: isDirectory, size: OMMetrics.fileIconList)
        }
    }

    /// 标题:命中的字符加粗并着色。
    private var titleText: AttributedString {
        var text = AttributedString(item.title)
        guard !item.positions.isEmpty else { return text }
        var cursor = text.startIndex
        for index in 0..<item.title.count {
            let next = text.index(afterCharacter: cursor)
            if item.positions.contains(index) {
                text[cursor..<next].font = OMFonts.custom(13, weight: .bold) // ui-lint:allow 搜索命中高亮属于内容强调
                text[cursor..<next].foregroundColor = OMColors.accent
            }
            cursor = next
        }
        return text
    }
}

/// 主题行:专为主题设计的生动视觉行(生活化文案、明暗微标、四色圆点色盘、当前使用打勾)。
private struct HubThemeRow: View {
    let item: HubItem
    let package: ThemePackage
    let selected: Bool
    let hovering: Bool
    /// 「当前使用」以已提交主题为准,键盘预览期间不随预览项漂移
    private var isCurrent: Bool { HubModel.shared.committedThemeID == package.id }

    var body: some View {
        HStack(spacing: 12) {
            Image.om("paintbrush", size: 14)
                .foregroundStyle(package.palette?.accent.color ?? OMColors.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(titleText)
                        .font(OMFonts.body.weight(.medium))
                        .lineLimit(1)

                    let badge = ThemePersonality.toneBadge(for: package)
                    Text(badge.text)
                        .font(OMFonts.custom(10.5, weight: .medium))
                        .foregroundStyle(badge.fg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(badge.bg, in: OMPillShape())

                    if isCurrent {
                        Text("当前使用")
                            .font(OMFonts.custom(10, weight: .medium))
                            .foregroundStyle(OMColors.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(OMColors.selectedFill, in: OMPillShape())
                    }
                }

                Text(ThemePersonality.tagline(for: package))
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // 4 个色块圆点预览
            HStack(spacing: 4) {
                ForEach(Array(ThemePersonality.swatches(for: package).enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().strokeBorder(OMColors.hairline.opacity(0.6), lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(OMColors.surface.opacity(0.6), in: OMPillShape())
            .overlay(OMPillShape().strokeBorder(OMColors.hairline.opacity(0.4), lineWidth: 0.5))

            if isCurrent {
                Image.om("check", size: 12)
                    .foregroundStyle(OMColors.accent)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(selected ? OMColors.selectedFill : (hovering ? OMColors.hoverFill : .clear), in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
        .contentShape(Rectangle())
    }

    private var titleText: AttributedString {
        var text = AttributedString(item.title)
        guard !item.positions.isEmpty else { return text }
        var cursor = text.startIndex
        for index in 0..<item.title.count {
            let next = text.index(afterCharacter: cursor)
            if item.positions.contains(index) {
                text[cursor..<next].font = OMFonts.custom(13, weight: .bold) // ui-lint:allow 搜索命中高亮属于内容强调
                text[cursor..<next].foregroundColor = OMColors.accent
            }
            cursor = next
        }
        return text
    }
}
