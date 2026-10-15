// @author ygw
// 左栏「会话」视图:项目 → 会话树。点击项目内「新对话」即在该目录下提问;支持置顶、移除、拖入目录添加项目。

import IconKit
import ACPKit
import ChatKit
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchKit

struct ProjectTreeView: View {
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        List {
            ForEach(workbench.orderedProjects) { project in
                ProjectSection(workbench: workbench, project: project)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if workbench.projects.isEmpty {
                ContentUnavailableView {
                    Label("没有项目", om: "folder.badge.plus")
                } description: {
                    Text("添加一个项目目录,或把文件夹拖到这里。")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    if let url = WorkspaceStore.chooseDirectory() { AppActions.shared.openWorkspace(url) }
                } label: {
                    Label("添加项目…", om: "folder.badge.plus")
                        .font(OMFonts.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
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
}

/// 项目节点及其会话行。
private struct ProjectSection: View {
    let workbench: WorkbenchModel
    let project: ProjectEntry
    @State private var hovering = false
    @State private var showAll = false

    private var isSelected: Bool { workbench.selectedProjectID == project.id }
    private var model: SessionModel? { workbench.sessions[project.id] }

    /// 展示用的会话列表:优先使用在线的历史列表,否则用缓存;不含当前会话。
    private var history: [CachedSession] {
        let source: [CachedSession] = {
            if let live = model?.history, !live.isEmpty {
                return live.map { CachedSession(sessionId: $0.sessionId, title: $0.title, updatedAt: $0.updatedAt) }
            }
            return project.sessions
        }()
        return source.filter { $0.sessionId != model?.sessionId }
    }

    var body: some View {
        Section(isExpanded: Binding(get: { !project.collapsed }, set: { _ in workbench.toggleCollapsed(project.id) })) {
            if let model, isSelected || model.sessionId != nil || model.isRunning {
                SessionRow(
                    title: model.sessionTitle ?? String(localized: "新对话"),
                    subtitle: model.isRunning ? String(localized: "工作中…") : nil,
                    uid: model.uid,
                    isCurrent: true,
                    isSelected: isSelected
                )
                .contentShape(Rectangle())
                .onTapGesture { workbench.select(project: project.id) }
            }
            let rows = showAll ? history : Array(history.prefix(8))
            ForEach(rows) { item in
                SessionRow(title: item.title ?? String(localized: "未命名对话"), subtitle: Self.relativeTime(item.updatedAt), uid: nil, isCurrent: false, isSelected: false)
                    .contentShape(Rectangle())
                    .onTapGesture { workbench.openHistory(project: project.id, sessionId: item.sessionId, title: item.title) }
                    .contextMenu {
                        Button("打开") { workbench.openHistory(project: project.id, sessionId: item.sessionId, title: item.title) }
                        if let model, model.capabilities.canDelete {
                            Divider()
                            Button("删除", role: .destructive) {
                                model.deleteSession(SessionSummary(sessionId: item.sessionId, cwd: project.id, title: item.title))
                            }
                        }
                    }
            }
            if history.count > 8 {
                Button(showAll ? "收起" : "显示全部 \(history.count) 个会话") { showAll.toggle() }
                    .buttonStyle(.plain)
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
            }
        } header: {
            header
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image.om(isSelected ? "folder.fill" : "folder")
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
                    Image.om("square.and.pencil")
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

    private static func relativeTime(_ text: String?) -> String? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        return date?.formatted(.relative(presentation: .named))
    }
}

/// 会话行:标题 + 副标题 + 状态点。
private struct SessionRow: View {
    let title: String
    let subtitle: String?
    let uid: String?
    let isCurrent: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image.om(isCurrent ? "bubble.left.fill" : "bubble.left", size: 11)
                .foregroundStyle(isCurrent && isSelected ? OMColors.accent : OMColors.tertiaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).font(OMFonts.body)
                if let subtitle {
                    Text(subtitle).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let uid { AttentionDot(uid: uid) }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background {
            if isCurrent && isSelected {
                RoundedRectangle(cornerRadius: 7).fill(OMColors.accent.opacity(0.14))
            }
        }
        .accessibilityElement(children: .combine)
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
