// @author ygw
// 标签内容:会话、文件(EditorKit 只读)、单文件 Diff、本轮改动汇总;其余类型暂以占位说明。

import ACPKit
import ChatKit
import DesignSystem
import DiffKit
import EditorKit
import IconKit
import OMLog
import SwiftUI
import WorkbenchKit

/// 按标签类型分发内容视图。
struct TabContentView: View {
    let workbench: WorkbenchModel
    let tab: WorkbenchTab

    var body: some View {
        switch tab.kind {
        case .chat(let projectID): ChatPane(workbench: workbench, projectID: projectID)
        case .file(let path): FileTabView(workbench: workbench, tab: tab, path: path)
        case .diff(let path): DiffTabView(workbench: workbench, path: path)
        case .changes(let projectID): ChangesTabView(workbench: workbench, projectID: projectID)
        case .subagent(let projectID, let toolCallID): SubagentTabView(workbench: workbench, projectID: projectID, toolCallID: toolCallID)
        case .preview(let id): PreviewTabView(id: id)
        case .terminal:
            ContentUnavailableView {
                Label("此类型的标签尚未提供", om: "info", size: 28)
            } description: {
                Text(tab.title)
            }
        }
    }
}

/// 会话内容:项目会话尚未创建时按需创建。
private struct ChatPane: View {
    let workbench: WorkbenchModel
    let projectID: String
    private let appearance = AppearanceModel.shared

    var body: some View {
        Group {
            if let model = workbench.sessions[projectID] {
                ChatView(model: model)
                    .id(appearance.fontRevision)
                    .environment(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { workbench.ensureSession(for: projectID) }
    }
}

/// 文件标签:可编辑的代码编辑器;文本保存在 `FileDocumentStore`,切换标签不丢失未保存内容。
struct FileTabView: View {
    let workbench: WorkbenchModel
    let tab: WorkbenchTab
    let path: String
    private let store = FileDocumentStore.shared

    var body: some View {
        let doc = store.document(for: path)
        VStack(spacing: 0) {
            banner(doc)
            Group {
                if let text = doc.text {
                    CodeEditor(text: text, language: SyntaxLanguage.detect(path: path), isEditable: !doc.isReadOnly, revealLine: tab.line) { newText in
                        doc.text = newText
                    }
                } else if let failure = doc.loadError {
                    Text(failure).foregroundStyle(OMColors.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: doc.isDirty, initial: true) { _, dirty in
            workbench.dock.setDirty(dirty, for: tab.id)
        }
        .task(id: path) {
            // 轮询磁盘修改时间:Agent 或其它程序改动文件后,未编辑的标签自动刷新
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await store.checkExternalChange(path)
            }
        }
    }

    /// 只读与外部修改提示条。
    @ViewBuilder
    private func banner(_ doc: FileDocument) -> some View {
        if doc.isReadOnly {
            noticeBar(icon: "lock", text: String(localized: "文件超过 5 MB,以只读方式打开")) { EmptyView() }
        } else if doc.externalChange {
            noticeBar(icon: "triangle-alert", text: String(localized: "文件已在磁盘上被修改,与你的未保存编辑冲突")) {
                Button("重新载入") { Task { await store.reload(path) } }.controlSize(.small)
                Button("保留我的") { Task { await store.save(path); AppActions.shared.refreshDirtyFlags() } }.controlSize(.small)
            }
        }
    }

    private func noticeBar<Actions: View>(icon: String, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Image.om(icon, size: 13).foregroundStyle(OMColors.warning)
            Text(text).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            Spacer()
            actions()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(OMColors.warning.opacity(0.12))
    }
}

/// 在所有会话的时间线中查找某文件最近一次改动。
@MainActor
private func latestChange(for path: String, in workbench: WorkbenchModel) -> (model: SessionModel, change: FileChange)? {
    for model in workbench.sessions.values {
        for entry in model.timeline.entries.reversed() where entry.kind == .changes {
            if let change = entry.changes.first(where: { $0.path == path }) { return (model, change) }
        }
    }
    return nil
}

/// 单文件 Diff 标签。
struct DiffTabView: View {
    let workbench: WorkbenchModel
    let path: String

    var body: some View {
        if let found = latestChange(for: path, in: workbench) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text((path as NSString).abbreviatingWithTildeInPath).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                        Text("+\(found.change.diff.added)").foregroundStyle(OMColors.diffAdded)
                        Text("−\(found.change.diff.removed)").foregroundStyle(OMColors.diffRemoved)
                        Spacer()
                        Button("在编辑器中打开") { workbench.openFile(path, line: found.change.diff.hunks.first?.newStart, preview: false) }
                            .controlSize(.small)
                        if found.change.status == .pending || found.change.status == .partiallyReverted {
                            Button("撤销") { found.model.revert(found.change) }.controlSize(.small)
                        }
                    }
                    .font(OMFonts.small)
                    DiffView(diff: found.change.diff, onRevertHunk: found.change.status == .reverted ? nil : { hunk in
                        found.model.revert(found.change, hunks: [hunk])
                    })
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView {
                Label("没有这个文件的改动记录", om: "file-diff", size: 28)
            } description: {
                Text((path as NSString).abbreviatingWithTildeInPath)
            }
        }
    }
}

/// 本轮改动汇总标签。
struct ChangesTabView: View {
    let workbench: WorkbenchModel
    let projectID: String

    var body: some View {
        if let model = workbench.sessions[projectID],
           let entry = model.timeline.entries.last(where: { $0.kind == .changes && !$0.changes.isEmpty }) {
            ScrollView {
                ChangesSummaryView(entry: entry)
                    .environment(model)
                    .padding(14)
            }
        } else {
            ContentUnavailableView {
                Label("暂无改动", om: "file-diff", size: 28)
            } description: {
                Text("Agent 修改文件后,这里会列出每个文件的差异。")
            }
        }
    }
}

/// 子 Agent 标签:只读展示子 Agent 的完整会话(含内部工具行、分组与实时状态)。
struct SubagentTabView: View {
    let workbench: WorkbenchModel
    let projectID: String
    let toolCallID: String

    var body: some View {
        if let model = workbench.sessions[projectID],
           let entry = model.timeline.toolEntry(id: toolCallID), let tool = entry.tool {
            VStack(spacing: 0) {
                header(tool: tool, entry: entry)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let child = entry.childStore, !child.entries.isEmpty {
                            ForEach(TimelineGrouping.group(child.entries)) { item in
                                TimelineItemView(item: item)
                            }
                        } else {
                            Text("子 Agent 还没有产生内容").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                        }
                    }
                    .frame(maxWidth: OMMetrics.timelineMaxWidth, alignment: .leading)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.top)
            }
            .environment(model)
            .background(OMColors.surface)
        } else {
            ContentUnavailableView {
                Label("这个子任务已不可用", om: "bot", size: 28)
            } description: {
                Text("会话被切换或重置后,原来的子任务内容不会保留。")
            }
        }
    }

    private func header(tool: ToolCall, entry: TimelineEntry) -> some View {
        HStack(spacing: 8) {
            Image.om("bot", size: 14).foregroundStyle(OMColors.accent)
            Text(tool.title).font(OMFonts.body.weight(.semibold)).lineLimit(1)
            if tool.status.isTerminal {
                OMTag(tool.status == .failed ? String(localized: "失败") : String(localized: "已完成"), tint: tool.status == .failed ? .red : .green)
            } else {
                OMTag(String(localized: "运行中"), tint: OMColors.accent)
            }
            Spacer()
            Text("只读").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}
