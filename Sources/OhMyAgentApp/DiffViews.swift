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
    private let softLimit = 300
    @State private var showAll = false

    var body: some View {
        let total = diff.hunks.reduce(0) { $0 + $1.lines.count }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleHunks(total: total)) { hunk in
                HunkView(hunk: hunk, onRevert: onRevertHunk.map { callback in { callback(hunk.id) } },
                         extraActions: extraActions.map { action in (action.title, { action.perform(hunk.id) }) })
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
            VStack(alignment: .leading, spacing: 0) {
                let marks = InlineDiff.highlights(for: hunk.lines)
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                    DiffLineRow(line: line, mark: marks[index])
                }
            }
        }
        .background(OMDiffPalette.background(.context))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
    }
}

/// 单行:左侧一个整块的行号槽(独立底色 + 强调色条),右侧正文;背景为不透明色并略向上下外扩,避免行间接缝。
struct DiffLineRow: View {
    let line: DiffLine
    /// 行内变化区间(词级高亮),nil 表示整行同色
    var mark: Range<Int>?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: 34, alignment: .trailing)
                Text(line.newNumber.map(String.init) ?? "")
                    .frame(width: 34, alignment: .trailing)
            }
            .foregroundStyle(OMColors.tertiaryText)
            .padding(.horizontal, 4)
            .frame(maxHeight: .infinity, alignment: .top)
            .diffFill(OMDiffPalette.gutter(paletteKind))
            .overlay(alignment: .leading) { Rectangle().fill(OMDiffPalette.bar(paletteKind)).frame(width: 3).padding(.vertical, -0.5) }
            Text(sign)
                .frame(width: 18)
                .frame(maxHeight: .infinity, alignment: .top)
                .diffFill(OMDiffPalette.background(paletteKind))
            Text(content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                .frame(maxHeight: .infinity, alignment: .top)
                .diffFill(OMDiffPalette.background(paletteKind))
        }
        .font(OMFonts.monoSmall)
        .foregroundStyle(line.kind == .context ? OMColors.secondaryText : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityKind) \(line.text)")
    }

    private var paletteKind: OMDiffPalette.Kind {
        switch line.kind {
        case .added: return .added
        case .removed: return .removed
        case .context: return .context
        }
    }

    /// 正文:有行内区间时,变化部分使用更深的底色。
    private var content: AttributedString {
        var text = AttributedString(line.text.isEmpty ? " " : line.text)
        guard let mark, line.kind != .context else { return text }
        let characters = text.characters
        guard mark.upperBound <= characters.count, mark.lowerBound < mark.upperBound else { return text }
        let start = characters.index(characters.startIndex, offsetBy: mark.lowerBound)
        let end = characters.index(characters.startIndex, offsetBy: mark.upperBound)
        text[start..<end].backgroundColor = (line.kind == .added ? OMColors.diffAdded : OMColors.diffRemoved).opacity(0.38)
        return text
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
        case .added: return String(localized: "新增")
        case .removed: return String(localized: "删除")
        case .context: return String(localized: "上下文")
        }
    }
}

extension View {
    /// 以不透明色铺满并向上下各外扩 0.5pt(相邻行互相覆盖,消除小数行高产生的接缝)。
    func diffFill(_ color: Color) -> some View {
        background { Rectangle().fill(color).padding(.vertical, -0.5) }
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
                    Image.om("doc.text")
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
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(path)#\(newText.count)#\(oldText?.count ?? -1)") {
            let (old, new) = (oldText, newText)
            diff = await Task.detached(priority: .userInitiated) { LineDiff.diff(old: old, new: new) }.value
        }
    }
}
