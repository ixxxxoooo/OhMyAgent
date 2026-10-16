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

    var body: some View {
        let blocks = MarkdownCache.blocks(for: text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
    }
}

/// 把行内 Markdown 转为 AttributedString;失败时回退为纯文本。
/// - Parameter source: 原文
func inlineMarkdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    guard var result = try? AttributedString(markdown: source, options: options) else { return AttributedString(source) }
    // 链接使用第二强调色(与主强调色区分)
    let linkColor = OMColors.accent2
    for run in result.runs where run.link != nil {
        result[run.range].foregroundColor = linkColor
    }
    return result
}

/// 单个块的视图。
struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(OMFonts.reading)
                .lineSpacing(3)
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
                                .font(.system(size: 12))
                        } else {
                            Text(item.marker).foregroundStyle(OMColors.secondaryText)
                        }
                        Text(inlineMarkdown(item.text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(OMFonts.reading)
                    .padding(.leading, CGFloat(item.level) * 16)
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(OMColors.hairline).frame(width: 3)
                Text(inlineMarkdown(text))
                    .font(OMFonts.reading)
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
                .help(copied ? String(localized: "已复制") : String(localized: "复制代码"))
                .accessibilityLabel(copied ? String(localized: "已复制") : String(localized: "复制代码"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.attributed(code, fence: language))
                    .font(OMFonts.readingMono)
                    .padding(12)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .omSolidCard(cornerRadius: 10)
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
                    Text(inlineMarkdown(cell)).font(OMFonts.small.weight(.semibold))
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(inlineMarkdown(cell)).font(OMFonts.small)
                    }
                }
            }
        }
        .padding(10)
        .omSolidCard(cornerRadius: 10)
    }
}
