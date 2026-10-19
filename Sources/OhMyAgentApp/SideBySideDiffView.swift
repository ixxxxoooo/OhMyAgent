// @author ixxxxoooo
// 并排 Diff 视图:左旧右新、行对齐;每块可撤销;超大差异默认只渲染前 300 行。

import DesignSystem
import DiffKit
import SwiftUI

/// 渲染一份 FileDiff 的并排形式。
struct SideBySideDiffView: View {
    let diff: FileDiff
    var onRevertHunk: ((Int) -> Void)?
    var extraActions: [DiffHunkAction] = []
    @State private var showAll = false

    var body: some View {
        let total = diff.hunks.reduce(0) { $0 + $1.lines.count }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleHunks(total: total)) { hunk in
                SideBySideHunkView(hunk: hunk, onRevert: onRevertHunk.map { callback in { callback(hunk.id) } },
                                   extraActions: extraActions.map { action in (action.title, { action.perform(hunk.id) }) })
            }
            if total > DiffSoftLimit.lines, !showAll {
                Button("显示全部 \(total) 行") { showAll = true }
                    .buttonStyle(.link)
                    .font(OMFonts.small)
            }
        }
    }

    private func visibleHunks(total: Int) -> [DiffHunk] {
        DiffSoftLimit.visible(diff.hunks, total: total, showAll: showAll)
    }
}

/// 单个块的并排渲染。
private struct SideBySideHunkView: View {
    let hunk: DiffHunk
    var onRevert: (() -> Void)?
    var extraActions: [(title: String, action: () -> Void)] = []

    var body: some View {
        let rows = SideBySide.rows(for: hunk)
        let marks = InlineDiff.highlights(for: hunk.lines)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hunk.header).font(OMFonts.monoSmall).foregroundStyle(OMColors.secondaryText)
                Spacer()
                ForEach(Array(extraActions.enumerated()), id: \.offset) { _, extra in
                    Button(extra.title, action: extra.action)
                        .buttonStyle(.plain)
                        .font(OMFonts.caption)
                        .foregroundStyle(OMColors.accent)
                }
                if let onRevert {
                    Button("撤销此块", action: onRevert)
                        .buttonStyle(.plain)
                        .font(OMFonts.caption)
                        .foregroundStyle(OMColors.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            Divider()
            // 左右各一个 AppKit 文本叶子(不折行,行高一致所以逐行天然对齐;长行在各自叶子内水平滚动):
            // 没有对应行的一侧用空行占位,复制各侧只得到该侧的代码正文
            HStack(alignment: .top, spacing: 0) {
                DiffTextLeaf(lines: rows.map(\.left), marks: rows.map { row in row.leftIndex.flatMap { marks[$0] } },
                             twoColumns: false, side: .old, wrap: false)
                Rectangle().fill(OMColors.hairline).frame(width: 0.5)
                DiffTextLeaf(lines: rows.map(\.right), marks: rows.map { row in row.rightIndex.flatMap { marks[$0] } },
                             twoColumns: false, side: .new, wrap: false)
            }
        }
        .background(OMDiffPalette.background(.context))
        .clipShape(RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
    }
}
