// @author ixxxxoooo
// 具体的文本叶子视图:代码块、终端输出、普通文字、Diff。都是 `OMTextLeaf` 的薄封装,
// 负责把业务参数折成「内容 + 样式」签名与富文本构造闭包。

import AppKit
import ChatKit
import DesignSystem
import DiffKit
import SwiftUI

/// 代码块正文(语法高亮;自动折行或在叶子内水平滚动)。
struct CodeTextLeaf: View {
    let language: String?
    let code: String
    var wrap: Bool

    var body: some View {
        var hasher = Hasher()
        hasher.combine(code)
        hasher.combine(language)
        hasher.combine(OMLeafStyle.current)
        return OMTextLeaf(
            signature: hasher.finalize(),
            config: OMTextLeafConfig(wrap: wrap, inset: NSSize(width: 12, height: 12))
        ) { OMLeafContent.code(code, fence: language) }
        .id(wrap)
        .accessibilityLabel(String(localized: "代码"))
    }
}

/// 终端/工具输出正文(ANSI 着色或纯文本;只渲染末尾若干行)。
struct OutputTextLeaf: View {
    let raw: String
    var fontSize: CGFloat = 12
    /// 最多渲染的末尾行数
    var maxLines = 400
    /// 是否按 ANSI 解析
    var ansi = true
    /// 默认文字色
    var tint: Color = OMColors.secondaryText

    var body: some View {
        var hasher = Hasher()
        hasher.combine(raw)
        hasher.combine(fontSize)
        hasher.combine(maxLines)
        hasher.combine(ansi)
        hasher.combine(OMLeafStyle.current)
        let color = NSColor(tint)
        hasher.combine(color.usingColorSpace(.sRGB)?.hashValue ?? 0)
        return OMTextLeaf(signature: hasher.finalize()) {
            OMLeafContent.output(raw, fontSize: fontSize, maxLines: maxLines, ansi: ansi, tint: color)
        }
    }
}

/// 普通文字叶子(用户消息、思考、提示正文)。
struct ProseTextLeaf: View {
    let text: String
    /// 基准字号
    var size: CGFloat = 13
    var color: Color = OMColors.primaryText
    /// 是否乘「时间线字号」
    var timeline = true
    /// 无选区的单击回调
    var onClick: (() -> Void)?
    /// 用户消息的工作区:非空时正文里的 `@路径` 渲染为文件 chip
    var mentionWorkspace: URL?

    var body: some View {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(mentionWorkspace)
        hasher.combine(size)
        hasher.combine(timeline)
        hasher.combine(OMLeafStyle.current)
        let resolved = NSColor(color)
        hasher.combine(resolved.usingColorSpace(.sRGB)?.hashValue ?? 0)
        return OMTextLeaf(signature: hasher.finalize(), onPlainClick: onClick) {
            if let mentionWorkspace {
                OMLeafContent.userMessage(text, workspace: mentionWorkspace, size: size, color: resolved, timeline: timeline)
            } else {
                OMLeafContent.prose(text, size: size, color: resolved, timeline: timeline)
            }
        }
    }
}

/// Diff 行组叶子:一个文本视图画出整块(行号槽与底色由布局管理器绘制,复制只得到正文)。
struct DiffTextLeaf: View {
    let lines: [DiffLine?]
    /// 行内变化区间;nil 时按 `lines`(不含占位)在构造富文本时才计算,避免每次 body 重算都跑词级 Diff
    var marks: [Range<Int>?]?
    var twoColumns = true
    var side: OMLeafContent.DiffSide = .both
    var wrap = true

    var body: some View {
        var hasher = Hasher()
        hasher.combine(lines.count)
        for line in lines { hasher.combine(line) }
        hasher.combine(twoColumns)
        hasher.combine(wrap)
        hasher.combine(OMLeafStyle.current)
        return OMTextLeaf(
            signature: hasher.finalize(),
            config: OMTextLeafConfig(wrap: wrap, inset: .zero, trailingPadding: 8)
        ) {
            OMLeafContent.diff(lines, marks: marks ?? InlineDiff.highlights(for: lines.compactMap { $0 }), twoColumns: twoColumns, side: side)
        }
        .id(wrap)
    }
}

/// 表格叶子:`NSTextTable` 原生表格排版;列宽按可用宽度分配,长文本在单元格内折行(只有每列压到最小仍放不下时才在叶子内横向滚动);复制得到制表符分隔文本。
struct TableTextLeaf: View {
    let header: [String]
    let rows: [[String]]
    /// 每列对齐
    var aligns: [MarkdownTableAlign] = []
    /// 宽松排版(文档阅读页)
    var roomy = false
    /// 可用宽度(由外层量得并量化);nil 表示未知,列宽只按单列上限封顶
    var availableWidth: CGFloat?

    var body: some View {
        var hasher = Hasher()
        hasher.combine(header)
        hasher.combine(rows)
        hasher.combine(aligns)
        hasher.combine(OMLeafStyle.current)
        hasher.combine(roomy)
        hasher.combine(availableWidth)
        return OMTextLeaf(
            signature: hasher.finalize(),
            // 内边距由单元格自己带;超宽时一律常驻滚动条(悬浮滚动条只在滚动时才出现,用户不知道可以横向滚动)
            config: OMTextLeafConfig(wrap: false, inset: .zero, persistentScroller: true, hugsContent: true)
        ) { OMLeafContent.table(header: header, rows: rows, aligns: aligns, roomy: roomy, maxWidth: availableWidth) }
        .accessibilityLabel(String(localized: "表格"))
    }
}
