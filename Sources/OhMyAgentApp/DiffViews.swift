// @author ygw
// Diff 视图:按块展示新增/删除行与行号;可选“撤销此块”。差异计算放到后台,避免大文件卡主线程。

import DesignSystem
import DiffKit
import SwiftUI

/// 渲染一份已计算好的 FileDiff。
struct DiffView: View {
    let diff: FileDiff
    /// 提供时每个块显示“撤销此块”按钮
    var onRevertHunk: ((Int) -> Void)?
    /// 单次最多渲染的行数,超出需手动展开
    private let softLimit = 300
    @State private var showAll = false

    var body: some View {
        let total = diff.hunks.reduce(0) { $0 + $1.lines.count }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleHunks(total: total)) { hunk in
                HunkView(hunk: hunk, onRevert: onRevertHunk.map { callback in { callback(hunk.id) } })
            }
            if total > softLimit, !showAll {
                Button("显示全部 \(total) 行") { showAll = true }
                    .buttonStyle(.link)
                    .font(OMFonts.small)
            }
        }
    }

    private func visibleHunks(total: Int) -> [DiffHunk] {
        guard total > softLimit, !showAll else { return diff.hunks }
        var budget = softLimit
        var result: [DiffHunk] = []
        for hunk in diff.hunks where budget > 0 {
            result.append(hunk)
            budget -= hunk.lines.count
        }
        return result
    }
}

/// 单个块。
struct HunkView: View {
    let hunk: DiffHunk
    var onRevert: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hunk.header)
                    .font(OMFonts.monoSmall)
                    .foregroundStyle(OMColors.secondaryText)
                Spacer()
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
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineRow(line: line)
                }
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 单行。
struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(OMColors.tertiaryText)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(OMColors.tertiaryText)
            Text(sign)
                .frame(width: 18)
            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .font(OMFonts.monoSmall)
        .foregroundStyle(line.kind == .context ? OMColors.secondaryText : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityKind) \(line.text)")
    }

    private var sign: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return ""
        }
    }

    private var accessibilityKind: String {
        switch line.kind {
        case .added: return "新增"
        case .removed: return "删除"
        case .context: return "上下文"
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return OMColors.diffAdded.opacity(0.16)
        case .removed: return OMColors.diffRemoved.opacity(0.16)
        case .context: return .clear
        }
    }
}

/// 由旧/新文本片段计算并展示 Diff(工具卡片、权限预览使用)。
struct SnippetDiffView: View {
    let path: String
    let oldText: String?
    let newText: String
    @State private var diff: FileDiff?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                Text((path as NSString).lastPathComponent).font(OMFonts.small.weight(.medium))
                if let diff {
                    Text("+\(diff.added)").foregroundStyle(OMColors.diffAdded)
                    Text("−\(diff.removed)").foregroundStyle(OMColors.diffRemoved)
                }
                Spacer()
            }
            .font(OMFonts.small)
            if let diff {
                DiffView(diff: diff)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(path)#\(newText.count)#\(oldText?.count ?? -1)") {
            let (old, new) = (oldText, newText)
            diff = await Task.detached(priority: .userInitiated) { LineDiff.diff(old: old, new: new) }.value
        }
    }
}
