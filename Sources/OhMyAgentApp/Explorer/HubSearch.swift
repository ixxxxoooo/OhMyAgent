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
    private(set) var sections: [HubSection] = []
    @ObservationIgnored private weak var workbench: WorkbenchModel?
    @ObservationIgnored private var commands: [String: PaletteCommand] = [:]
    /// 候选缓存:打开窗口时构建一次(文件索引完成后重建),输入时只做排序
    @ObservationIgnored private var candidates: [HubCandidate] = []

    /// 平铺的结果(键盘选择用)。
    var flatItems: [HubItem] { sections.flatMap(\.items) }

    /// 打开搜索窗。
    /// - Parameters:
    ///   - segment: 初始分类
    ///   - workbench: 工作台
    ///   - query: 预填查询
    func present(_ segment: HubSegment = .all, workbench: WorkbenchModel, query: String = "") {
        self.workbench = workbench
        self.segment = segment
        self.query = query
        selection = 0
        isPresented = true
        if WorkspaceIndexModel.shared.root != workbench.selectedProjectID || WorkspaceIndexModel.shared.files.isEmpty {
            WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
        }
        rebuildCandidates()
        Log.ui.info("打开中央搜索", ["segment": segment.rawValue])
    }

    /// 关闭搜索窗。
    func dismiss() { isPresented = false }

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
        if selection >= flatItems.count { selection = max(flatItems.count - 1, 0) }
    }

    /// 移动选中项(循环)。
    func move(_ step: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        selection = ((selection + step) % count + count) % count
    }

    /// 执行当前选中项。
    func runSelected() {
        let items = flatItems
        guard items.indices.contains(selection) else { return }
        run(items[selection])
    }

    /// 执行某一项并关闭窗口。
    func run(_ item: HubItem) {
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
            for cached in project.sessions where !project.archivedSessions.contains(cached.sessionId) {
                let date = HubDates.parse(cached.updatedAt ?? cached.firstSeenAt)
                let title = (cached.title?.isEmpty == false ? cached.title : nil) ?? String(localized: "新对话")
                sessions.append((date ?? .distantPast, HubCandidate(
                    id: "session:\(cached.sessionId)", segment: .sessions, title: title, subtitle: project.name,
                    trailing: date.map(HubDates.relative), icon: .symbol("message-square"),
                    action: .session(workspace: project.id, sessionId: cached.sessionId, title: cached.title))))
            }
        }
        result += sessions.sorted { $0.0 > $1.0 }.map(\.1)
        // 项目:最近打开优先
        for project in workbench.projects.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }) {
            result.append(HubCandidate(
                id: "project:\(project.id)", segment: .projects, title: project.name,
                subtitle: (project.id as NSString).abbreviatingWithTildeInPath, trailing: nil,
                icon: .file(name: project.name, isDirectory: true), action: .project(path: project.id)))
        }
        // 文件:当前项目索引
        if let root = workbench.selectedProjectID, WorkspaceIndexModel.shared.root == root {
            for path in WorkspaceIndexModel.shared.files {
                let name = (path as NSString).lastPathComponent
                let dir = (path as NSString).deletingLastPathComponent
                result.append(HubCandidate(
                    id: "file:\(path)", segment: .files, title: name, subtitle: dir.isEmpty ? nil : dir, trailing: nil,
                    icon: .file(name: name, isDirectory: false), searchText: path, action: .file(root: root, relativePath: path)))
            }
        }
        // 操作:命令面板里的全部命令
        var table: [String: PaletteCommand] = [:]
        for command in PaletteCommands.all(workbench: workbench) + DemoPaletteCommands.all(workbench: workbench) {
            table[command.id] = command
            result.append(HubCandidate(
                id: "action:\(command.id)", segment: .actions, title: command.title, subtitle: nil, trailing: command.shortcut,
                icon: .symbol(command.icon), action: .command(id: command.id)))
        }
        // 设置:全部设置页(含别名关键词)
        for group in SettingsPage.groups {
            for page in group.pages {
                result.append(HubCandidate(
                    id: "settings:\(page.rawValue)", segment: .settings, title: page.title, subtitle: group.title, trailing: nil,
                    icon: .symbol(page.icon), keywords: page.keywords, action: .settings(page: page.rawValue)))
            }
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
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { hub.dismiss() }
                    .accessibilityHidden(true)
                card
                    .padding(.top, 84)
            }
            .transition(.opacity)
            .onChange(of: WorkspaceIndexModel.shared.files.count) { hub.rebuildCandidates() }
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
        .background(OMColors.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(OMColors.hairline))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("搜索")
    }

    // MARK: 输入框

    private var searchField: some View {
        HStack(spacing: 10) {
            Image.om("search", size: 18).foregroundStyle(OMColors.secondaryText)
            TextField("搜索会话、项目、文件、操作与设置", text: $hub.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($focused)
                .onSubmit { hub.runSelected() }
                .onKeyPress(.downArrow) { hub.move(1); return .handled }
                .onKeyPress(.upArrow) { hub.move(-1); return .handled }
                .onKeyPress(.tab) { hub.segment = hub.segment.next(by: NSEvent.modifierFlags.contains(.shift) ? -1 : 1); return .handled }
                .onKeyPress(.escape) { hub.dismiss(); return .handled }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    // MARK: 分类

    private var segments: some View {
        HStack(spacing: 4) {
            ForEach(HubSegment.allCases) { item in
                Button { hub.segment = item; focused = true } label: {
                    Text(item.title)
                        .font(OMFonts.small.weight(hub.segment == item ? .semibold : .regular))
                        .foregroundStyle(hub.segment == item ? Color.primary : OMColors.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(hub.segment == item ? Color.primary.opacity(0.08) : .clear, in: Capsule())
                        .contentShape(Capsule())
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
                                HubRow(item: item, selected: isSelected(item))
                                    .id(item.id)
                                    .onTapGesture { hub.run(item) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(isSelected(item) ? [.isButton, .isSelected] : .isButton)
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
        if hub.segment == .files || hub.segment == .all, WorkspaceIndexModel.shared.isLoading, hub.query.isEmpty == false {
            return String(localized: "正在建立文件索引…")
        }
        return hub.query.isEmpty ? String(localized: "这里还没有内容") : String(localized: "没有匹配项")
    }

    private func listHeight(_ sections: [HubSection]) -> CGFloat {
        let rows = sections.reduce(0) { $0 + $1.items.count }
        let headers = sections.filter { !$0.title.isEmpty }.count
        return CGFloat(rows) * 36 + CGFloat(headers) * 26 + 8
    }

    private func isSelected(_ item: HubItem) -> Bool {
        let flat = hub.flatItems
        return flat.indices.contains(hub.selection) && flat[hub.selection].id == item.id
    }

    // MARK: 底部提示

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "选择")
            hint("↩", "打开")
            hint("⇥", "切换分类")
            hint("esc", "关闭")
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
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(OMFonts.caption)
        }
        .foregroundStyle(OMColors.secondaryText)
    }
}

/// 结果行。
private struct HubRow: View {
    let item: HubItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 20)
            Text(titleText).font(.system(size: 13.5)).lineLimit(1)
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
        .background(selected ? OMColors.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                text[cursor..<next].font = .system(size: 13.5, weight: .bold)
                text[cursor..<next].foregroundColor = OMColors.accent
            }
            cursor = next
        }
        return text
    }
}
