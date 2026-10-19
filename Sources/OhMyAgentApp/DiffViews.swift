// @author ixxxxoooo
// Diff 视图:按块展示新增/删除行与行号;可选“撤销此块”。差异计算放到后台,避免大文件卡主线程。

import IconKit
import DesignSystem
import DiffKit
import SwiftUI

/// 块级附加操作(如「暂存此块」):按钮标题 + 以块 ID 为参数的回调。
struct DiffHunkAction: Identifiable {
    let title: String
    let perform: (Int) -> Void
    var id: String { title }
}

/// 渲染一份已计算好的 FileDiff。
struct DiffView: View {
    let diff: FileDiff
    /// 提供时每个块显示“撤销此块”按钮
    var onRevertHunk: ((Int) -> Void)?
    /// 额外的块级操作(显示在「撤销此块」之前)
    var extraActions: [DiffHunkAction] = []
    /// 单次最多渲染的行数,超出需手动展开
    @State private var showAll = false

    var body: some View {
        let total = diff.hunks.reduce(0) { $0 + $1.lines.count }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleHunks(total: total)) { hunk in
                HunkView(hunk: hunk, onRevert: onRevertHunk.map { callback in { callback(hunk.id) } },
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

/// 单个块。
struct HunkView: View {
    let hunk: DiffHunk
    var onRevert: (() -> Void)?
    var extraActions: [(title: String, action: () -> Void)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hunk.header)
                    .font(OMFonts.monoSmall)
                    .foregroundStyle(OMColors.secondaryText)
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
            // 整个块一个 AppKit 文本视图:行号槽与底色由布局管理器绘制,可跨行连续选择,复制只得到代码正文
            DiffTextLeaf(lines: hunk.lines.map { Optional($0) }, twoColumns: true, wrap: true)
        }
        .background(OMDiffPalette.background(.context))
        .clipShape(RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
    }
}

/// 由旧/新文本片段计算并展示 Diff(工具卡片、权限预览使用)。
struct SnippetDiffView: View {
    let path: String
    let oldText: String?
    let newText: String
    /// 是否显示文件名与统计头(工具行已显示时可关闭)
    var showHeader = true
    @State private var diff: FileDiff?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showHeader {
                HStack(spacing: 6) {
                    OMFileIcon(name: (path as NSString).lastPathComponent, size: 14)
                    Text((path as NSString).lastPathComponent).font(OMFonts.small.weight(.medium))
                    if let diff {
                        Text("+\(diff.added)").foregroundStyle(OMColors.diffAdded)
                        Text("−\(diff.removed)").foregroundStyle(OMColors.diffRemoved)
                    }
                    Spacer()
                }
                .font(OMFonts.small)
            }
            if let diff {
                DiffView(diff: diff)
            } else {
                OMSpinner(.small)
            }
        }
        .task(id: "\(path)#\(newText.count)#\(oldText?.count ?? -1)") {
            let (old, new) = (oldText, newText)
            diff = await Task.detached(priority: .userInitiated) { LineDiff.diff(old: old, new: new) }.value
        }
    }
}
