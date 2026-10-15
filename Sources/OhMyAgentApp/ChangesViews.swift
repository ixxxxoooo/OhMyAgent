// @author ygw
// “本轮改动”汇总与文件查看面板:逐文件审查、按块撤销、整体撤销;点击文件在 EditorKit 编辑器中打开。

import ChatKit
import DesignSystem
import DiffKit
import EditorKit
import SwiftUI

/// 本轮改动汇总卡片。
struct ChangesSummaryView: View {
    let entry: TimelineEntry
    @Environment(SessionModel.self) private var model

    var body: some View {
        let added = entry.changes.reduce(0) { $0 + $1.diff.added }
        let removed = entry.changes.reduce(0) { $0 + $1.diff.removed }
        let hasPending = entry.changes.contains { $0.status == .pending || $0.status == .partiallyReverted }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").foregroundStyle(OMColors.secondaryText)
                Text("本轮修改了 \(entry.changes.count) 个文件").font(OMFonts.small.weight(.semibold))
                Text("+\(added)").foregroundStyle(OMColors.diffAdded).font(OMFonts.small)
                Text("−\(removed)").foregroundStyle(OMColors.diffRemoved).font(OMFonts.small)
                Spacer()
                if hasPending {
                    Button("全部撤销") { model.revertAll(in: entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ForEach(entry.changes) { change in
                Divider()
                FileChangeRow(change: change)
            }
        }
        .omSolidCard(cornerRadius: 10)
    }
}

/// 单个文件改动行,可展开查看差异。
struct FileChangeRow: View {
    let change: FileChange
    @Environment(SessionModel.self) private var model
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    omWithAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(OMColors.tertiaryText)
                        Text(change.fileName).font(OMFonts.small.weight(.medium))
                        if change.original == nil { OMTag("新建", tint: .green) }
                        Text("+\(change.diff.added)").foregroundStyle(OMColors.diffAdded)
                        Text("−\(change.diff.removed)").foregroundStyle(OMColors.diffRemoved)
                        Spacer(minLength: 0)
                    }
                    .font(OMFonts.small)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                statusLabel
                Button {
                    model.viewerRequest = FileViewRequest(path: change.path, line: change.diff.hunks.first?.newStart)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.plain)
                .help("在编辑器中打开")
                .accessibilityLabel("在编辑器中打开 \(change.path)")
                if change.status == .pending || change.status == .partiallyReverted {
                    Button("撤销") { model.revert(change) }
                        .buttonStyle(.plain)
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            if expanded {
                DiffView(diff: change.diff, onRevertHunk: change.status == .reverted ? nil : { hunkId in
                    model.revert(change, hunks: [hunkId])
                })
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch change.status {
        case .pending: EmptyView()
        case .reverted: OMTag("已撤销")
        case .partiallyReverted: OMTag("部分撤销", tint: OMColors.warning)
        case .conflict: OMTag("文件已被修改,未撤销", tint: .red)
        case .failed(let message): OMTag("失败:\(message)", tint: .red)
        }
    }
}

/// 文件查看面板:使用 EditorKit(TextKit 2)只读展示,带语法高亮并跳转到指定行。
struct FileViewerSheet: View {
    let request: FileViewRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text")
                Text(request.path.abbreviatedPath).font(OMFonts.small).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            if let text {
                CodeEditor(text: text, language: SyntaxLanguage.detect(path: request.path), isEditable: false, revealLine: request.line)
            } else if let failure {
                Text(failure).foregroundStyle(OMColors.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            let path = request.path
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                try? String(contentsOfFile: path, encoding: .utf8)
            }.value
            if let result { text = result } else { failure = "无法读取文件(可能已被删除或不是文本文件)" }
        }
    }
}

private extension String {
    var abbreviatedPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
