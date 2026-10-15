// @author ygw
// 标签内容:会话、文件(EditorKit 只读)、单文件 Diff、本轮改动汇总;其余类型暂以占位说明。

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
        case .file(let path): FileTabView(path: path, line: tab.line)
        case .diff(let path): DiffTabView(workbench: workbench, path: path)
        case .changes(let projectID): ChangesTabView(workbench: workbench, projectID: projectID)
        case .subagent, .terminal, .preview:
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

/// 文件标签:后台读取,EditorKit 只读展示并定位到指定行。
struct FileTabView: View {
    let path: String
    let line: Int?
    @State private var text: String?
    @State private var failure: String?

    var body: some View {
        Group {
            if let text {
                CodeEditor(text: text, language: SyntaxLanguage.detect(path: path), isEditable: false, revealLine: line)
            } else if let failure {
                Text(failure).foregroundStyle(OMColors.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path) {
            let target = path
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                try? String(contentsOfFile: target, encoding: .utf8)
            }.value
            Log.ui.info("文件标签读取", ["path": target, "ok": "\(result != nil)", "len": "\(result?.count ?? -1)"])
            if let result { text = result; failure = nil } else { failure = String(localized: "无法读取文件(可能已被删除或不是文本文件)") }
        }
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
