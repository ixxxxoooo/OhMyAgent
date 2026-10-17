// @author ixxxxoooo
// Markdown 渲染:块级由 ChatKit.MarkdownParser 解析,行内交给系统 AttributedString。

import IconKit
import AppKit
import ChatKit
import DesignSystem
import EditorKit
import SwiftUI

/// Markdown 视图。
struct MarkdownView: View {
    let text: String
    /// 文本是否仍在流式增长(影响解析缓存策略,见 `MarkdownCache.blocks`)
    var streaming = false

    var body: some View {
        let blocks = MarkdownCache.blocks(for: text, streaming: streaming)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                // equatable:流式追加时只有末尾的块变化,其余块跳过 body 重算(含行内 Markdown 解析与代码高亮)
                MarkdownBlockView(block: block).equatable()
            }
        }
        .textSelection(.enabled)
    }
}

/// 把行内 Markdown 转为 AttributedString;失败时回退为纯文本。
/// 行内代码仅保留系统标记(`inlinePresentationIntent`),圆角底与等宽字体由 `InlineMarkdownText` 绘制。
/// - Parameter source: 原文
func inlineMarkdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    guard var result = try? AttributedString(markdown: source, options: options) else { return AttributedString(source) }
    // 链接使用第二强调色(与主强调色区分)
    let linkColor = OMColors.link
    for run in result.runs where run.link != nil {
        result[run.range].foregroundColor = linkColor
    }
    return result
}

/// 行内代码标记:`InlineCodeTextRenderer` 据此在文字后面画圆角底。
struct InlineCodeAttribute: TextAttribute {}

/// 行内代码渲染器:在带 `InlineCodeAttribute` 的文字后画圆角底(圆角取 `OMRadius.tag`),其余文字原样绘制。
/// 左右内边距由文字两侧的细空格(U+2009)提供,所以换行时底色不会贴边。
struct InlineCodeTextRenderer: TextRenderer {
    /// 底色
    var fill: Color
    /// 圆角
    var radius: CGFloat

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[InlineCodeAttribute.self] != nil {
                    let rect = run.typographicBounds.rect.insetBy(dx: 0, dy: -1)
                    context.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(fill))
                }
                context.draw(run)
            }
        }
    }
}

/// 把行内 Markdown 构造成 `Text`:普通片段沿用系统渲染(链接、粗体、斜体),行内代码片段换成等宽字体 + 强调色,并打上 `InlineCodeAttribute`。
/// - Parameter source: 行内 Markdown 原文
/// - Returns: 文本与是否含行内代码
@MainActor
func inlineMarkdownText(_ source: String) -> (text: Text, hasCode: Bool) {
    let attributed = inlineMarkdown(source)
    var result: Text?
    var hasCode = false
    for run in attributed.runs {
        let piece: Text
        if run.inlinePresentationIntent?.contains(.code) == true {
            hasCode = true
            let code = String(attributed[run.range].characters)
            piece = Text(verbatim: "\u{2009}\(code)\u{2009}")
                .font(OMFonts.readingMono)
                .foregroundStyle(OMColors.accentText)
                .customAttribute(InlineCodeAttribute())
        } else {
            piece = Text(AttributedString(attributed[run.range]))
        }
        result = result.map { Text("\($0)\(piece)") } ?? piece
    }
    return (result ?? Text(verbatim: ""), hasCode)
}

/// 行内 Markdown 文本:行内代码为圆角底并带内边距;其余与 `Text(inlineMarkdown(…))` 一致。
struct InlineMarkdownText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        let built = inlineMarkdownText(source)
        if built.hasCode {
            built.text.textRenderer(InlineCodeTextRenderer(fill: OMColors.accent.opacity(0.1), radius: OMRadius.tag))
        } else {
            built.text
        }
    }
}

/// 单个块的视图。
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdownText(text)
                .font(OMFonts.custom(headingSize(level), weight: .medium))
                .lineSpacing(OMFonts.lineSpacing(forSize: headingSize(level)))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            InlineMarkdownText(text)
                .font(OMFonts.reading)
                .lineSpacing(OMFonts.readingLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code, let isClosed):
            // 围栏闭合后才渲染 Mermaid,避免流式输出中途反复解析失败
            if isClosed, language?.lowercased() == "mermaid" {
                MermaidBlockView(source: code)
            } else {
                CodeBlockView(language: language, code: code)
            }
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let checked = item.checked {
                            Image.om(checked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(checked ? OMColors.accent : OMColors.secondaryText)
                                .font(OMFonts.small)
                        } else {
                            Text(item.marker).foregroundStyle(OMColors.secondaryText)
                        }
                        InlineMarkdownText(item.text)
                            .lineSpacing(OMFonts.readingLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(OMFonts.reading)
                    .padding(.leading, CGFloat(item.level) * 16)
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(OMColors.hairline).frame(width: 3) // ui-lint:allow 引用条细线圆角
                InlineMarkdownText(text)
                    .font(OMFonts.reading)
                    .lineSpacing(OMFonts.readingLineSpacing)
                    .foregroundStyle(OMColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let rows):
            TableBlockView(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        let base: CGFloat
        switch level {
        case 1: base = 20
        case 2: base = 17
        case 3: base = 15
        default: base = 14
        }
        return base * OMScale.ui * OMScale.timeline
    }
}

/// 代码块:纯色背景(阅读区不使用玻璃),带语言标签与复制按钮。
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false
    @AppStorage(ClientPrefs.Key.chatCodeWrap) private var wrapLines = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? String(localized: "代码"))
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image.om(copied ? "check" : "copy", size: 13)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? OMColors.success : OMColors.secondaryText)
                .omTooltip(copied ? String(localized: "已复制") : String(localized: "复制代码"))
                .accessibilityLabel(copied ? String(localized: "已复制") : String(localized: "复制代码"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if wrapLines {
                // 自动换行:代码块宽度固定为容器宽度,长行折行显示
                Text(CodeHighlighter.attributed(code, fence: language))
                    .font(OMFonts.readingMono)
                    .lineSpacing(OMFonts.readingMonoLineSpacing)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(CodeHighlighter.attributed(code, fence: language))
                        .font(OMFonts.readingMono)
                        .lineSpacing(OMFonts.readingMonoLineSpacing)
                        .padding(12)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .omSolidCard()
    }
}

/// 表格块。
struct TableBlockView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    InlineMarkdownText(cell).font(OMFonts.small.weight(.medium))
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        InlineMarkdownText(cell).font(OMFonts.small)
                    }
                }
            }
        }
        .padding(10)
        .omSolidCard()
    }
}
