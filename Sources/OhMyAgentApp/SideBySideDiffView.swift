// @author ixxxxoooo
// 并排 Diff 视图:左旧右新、行对齐;每块可撤销;超大差异默认只渲染前 300 行。

import DesignSystem
import DiffKit
import SwiftUI

/// 渲染一份 FileDiff 的并排形式。
struct SideBySideDiffView: View {
    let diff: FileDiff
    var onRevertHunk: ((Int) -> Void)?
    private let softLimit = 300
    @State private var showAll = false

    var body: some View {
        let total = diff.hunks.reduce(0) { $0 + $1.lines.count }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleHunks(total: total)) { hunk in
                SideBySideHunkView(hunk: hunk, onRevert: onRevertHunk.map { callback in { callback(hunk.id) } })
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

/// 单个块的并排渲染。
private struct SideBySideHunkView: View {
    let hunk: DiffHunk
    var onRevert: (() -> Void)?

    var body: some View {
        let rows = SideBySide.rows(for: hunk)
        let marks = InlineDiff.highlights(for: hunk.lines)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hunk.header).font(OMFonts.monoSmall).foregroundStyle(OMColors.secondaryText)
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
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 0) {
                        half(row.left, mark: row.leftIndex.flatMap { marks[$0] }, number: row.left?.oldNumber)
                        Rectangle().fill(OMColors.hairline).frame(width: 0.5)
                        half(row.right, mark: row.rightIndex.flatMap { marks[$0] }, number: row.right?.newNumber)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .background(OMDiffPalette.background(.context))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
    }

    /// 单侧:行号槽(独立底色 + 强调色条)+ 正文;空侧只显示灰底占位。
    private func half(_ line: DiffLine?, mark: Range<Int>?, number: Int?) -> some View {
        let kind = paletteKind(line)
        return HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(OMColors.tertiaryText)
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity, alignment: .top)
                .diffFill(OMDiffPalette.gutter(kind))
                .overlay(alignment: .leading) { Rectangle().fill(OMDiffPalette.bar(kind)).frame(width: 3).padding(.vertical, -0.5) }
            Text(content(line, mark: mark))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity, alignment: .top)
                .diffFill(OMDiffPalette.background(kind))
        }
        .font(OMFonts.monoSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.map { "\(kindLabel($0.kind)) \($0.text)" } ?? "")
    }

    private func paletteKind(_ line: DiffLine?) -> OMDiffPalette.Kind {
        guard let line else { return .empty }
        switch line.kind {
        case .added: return .added
        case .removed: return .removed
        case .context: return .context
        }
    }

    private func content(_ line: DiffLine?, mark: Range<Int>?) -> AttributedString {
        guard let line else { return AttributedString(" ") }
        var text = AttributedString(line.text.isEmpty ? " " : line.text)
        guard let mark, line.kind != .context else { return text }
        let characters = text.characters
        guard mark.upperBound <= characters.count, mark.lowerBound < mark.upperBound else { return text }
        let start = characters.index(characters.startIndex, offsetBy: mark.lowerBound)
        let end = characters.index(characters.startIndex, offsetBy: mark.upperBound)
        text[start..<end].backgroundColor = (line.kind == .added ? OMColors.diffAdded : OMColors.diffRemoved).opacity(0.38)
        return text
    }

    private func kindLabel(_ kind: DiffLineKind) -> String {
        switch kind {
        case .added: return String(localized: "新增")
        case .removed: return String(localized: "删除")
        case .context: return String(localized: "上下文")
        }
    }
}
