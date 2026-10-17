// @author ixxxxoooo
// “本轮改动”汇总与文件查看面板:逐文件审查、按块撤销、整体撤销;点击文件在 EditorKit 编辑器中打开。

import IconKit
import ChatKit
import DesignSystem
import DiffKit
import EditorKit
import SwiftUI

/// 本轮改动汇总卡片 (对标 Cursor 图 6 风格: 回合结束后展示，点击行直接打开差异对比标签页)。
struct ChangesSummaryView: View {
    let entry: TimelineEntry
    @Environment(SessionModel.self) private var model

    var body: some View {
        if model.isRunning {
            EmptyView()
        } else {
            let count = entry.changes.count
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("\(count) \(count == 1 ? "File Changed" : "Files Changed")")
                        .font(OMFonts.small.weight(.semibold))
                        .foregroundStyle(OMColors.primaryText)
                    Spacer()
                    Button {
                        if let first = entry.changes.first {
                            AppEnvironment.shared.workbench.openDiff(first.path)
                        } else {
                            AppEnvironment.shared.workbench.openChanges(project: model.workspace.path)
                        }
                    } label: {
                        Text("Review")
                            .font(OMFonts.caption.weight(.medium))
                            .foregroundStyle(OMColors.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(OMColors.hoverFill, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .omTooltip(String(localized: "审查全部差异"), icon: "file-diff")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                ForEach(entry.changes) { change in
                    Divider().overlay(OMColors.hairline.opacity(0.5))
                    FileChangeRow(change: change)
                }
            }
            .omSolidCard()
        }
    }
}

/// 单个文件改动行 (对标 Cursor 图 6: 点击直接在标签页打开差异对比)。
struct FileChangeRow: View {
    let change: FileChange
    @Environment(SessionModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                AppEnvironment.shared.workbench.openDiff(change.path)
            } label: {
                HStack(spacing: 8) {
                    OMFileIcon(name: change.fileName, size: 14)
                    Text(change.fileName)
                        .font(OMFonts.small.weight(.medium))
                        .foregroundStyle(OMColors.primaryText)
                        .lineLimit(1)
                    if change.original == nil { OMTag(String(localized: "新建"), tint: OMColors.success) }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            statusLabel

            if hovering {
                Button {
                    model.viewerRequest = FileViewRequest(path: change.path, line: change.diff.hunks.first?.newStart)
                } label: {
                    Image.om("arrow.up.forward.square", size: 13)
                        .foregroundStyle(OMColors.secondaryText)
                }
                .buttonStyle(.plain)
                .omTooltip("在编辑器中打开", icon: "arrow.up.forward.square")

                if change.status == .pending || change.status == .partiallyReverted {
                    Button {
                        model.revert(change)
                    } label: {
                        Image.om("undo-2", size: 12)
                            .foregroundStyle(OMColors.accent)
                    }
                    .buttonStyle(.plain)
                    .omTooltip("撤销修改", icon: "undo-2")
                }
            }

            Text("+\(change.diff.added)").foregroundStyle(OMColors.diffAdded).font(OMFonts.small)
            Text("−\(change.diff.removed)").foregroundStyle(OMColors.diffRemoved).font(OMFonts.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(hovering ? OMColors.hoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .omTooltip("点击打开标签查看差异", icon: "file-diff")
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch change.status {
        case .pending: EmptyView()
        case .reverted: OMTag(String(localized: "已撤销"))
        case .partiallyReverted: OMTag(String(localized: "部分撤销"), tint: OMColors.warning)
        case .conflict: OMTag(String(localized: "文件已被修改,未撤销"), tint: OMColors.danger)
        case .failed(let message): OMTag(String(localized: "失败:\(message)"), tint: OMColors.danger)
        }
    }
}

private extension String {
    var abbreviatedPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
