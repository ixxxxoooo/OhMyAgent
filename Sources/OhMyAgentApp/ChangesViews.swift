// @author ixxxxoooo
// “本轮改动”汇总与文件查看面板:逐文件审查、按块撤销、整体撤销;点击文件在 EditorKit 编辑器中打开。

import IconKit
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
                Image.om("doc.on.doc").foregroundStyle(OMColors.secondaryText)
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
                        Image.om("chevron.right", size: 9, weight: .bold)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(OMColors.tertiaryText)
                        Text(change.fileName).font(OMFonts.small.weight(.medium))
                        if change.original == nil { OMTag(String(localized: "新建"), tint: .green) }
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
                    Image.om("arrow.up.forward.square")
                }
                .buttonStyle(.plain)
                .help("在编辑器中打开")
                .accessibilityLabel("在编辑器中打开 \(change.path)")
                Button {
                    AppEnvironment.shared.workbench.openDiff(change.path)
                } label: {
                    Image.om("file-diff")
                }
                .buttonStyle(.plain)
                .help("在标签中查看差异")
                .accessibilityLabel("在标签中查看差异 \(change.path)")
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
        case .reverted: OMTag(String(localized: "已撤销"))
        case .partiallyReverted: OMTag(String(localized: "部分撤销"), tint: OMColors.warning)
        case .conflict: OMTag(String(localized: "文件已被修改,未撤销"), tint: .red)
        case .failed(let message): OMTag(String(localized: "失败:\(message)"), tint: .red)
        }
    }
}

private extension String {
    var abbreviatedPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
