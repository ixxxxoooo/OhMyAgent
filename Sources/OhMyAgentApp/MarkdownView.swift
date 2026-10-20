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
    /// 是否懒加载各段(放在 ScrollView 里的整页预览用,只排版可见段,避免大文档一次性排版卡主线程)
    var lazy = false
    @Environment(\.markdownDocument) private var document

    var body: some View {
        let segments = MarkdownSegment.split(MarkdownCache.blocks(for: text, streaming: streaming))
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: document ? 16 : 10) { segmentViews(segments) }
            } else {
                VStack(alignment: .leading, spacing: document ? 16 : 10) { segmentViews(segments) }
            }
        }
    }

    /// 各渲染段的视图。
    /// - Parameter segments: 渲染段序列
    /// - Returns: 段视图集合
    @ViewBuilder
    private func segmentViews(_ segments: [MarkdownSegment]) -> some View {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            // equatable:流式追加时只有末尾的段变化,其余段跳过 body 重算(含行内 Markdown 解析与代码高亮)
            switch segment {
            case .textRun(let blocks):
                // 相邻文字块合并为一个 NSTextView,支持跨段落连续选择与复制
                MarkdownTextRunView(blocks: blocks).equatable()
            case .block(let block):
                MarkdownBlockView(block: block).equatable()
            }
        }
    }
}

/// 渲染分段:连续的文字块合并为一段(AppKit 文本视图),其余块(代码、表格、分隔线)各自成段。
enum MarkdownSegment: Hashable {
    case textRun([MarkdownBlock])
    case block(MarkdownBlock)

    /// 把块序列切成渲染段。
    /// - Parameter blocks: 块序列
    /// - Returns: 渲染段序列
    static func split(_ blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        var result: [MarkdownSegment] = []
        var run: [MarkdownBlock] = []
        for block in blocks {
            if isTextRunBlock(block) {
                run.append(block)
            } else {
                if !run.isEmpty { result.append(.textRun(run)); run = [] }
                result.append(.block(block))
            }
        }
        if !run.isEmpty { result.append(.textRun(run)) }
        return result
    }
}

/// 把行内 Markdown 转为 AttributedString;失败时回退为纯文本。
/// 行内代码仅保留系统标记(`inlinePresentationIntent`),圆角底与等宽字体由 `InlineMarkdownText` 绘制。
/// - Parameter source: 原文
func inlineMarkdown(_ source: String) -> AttributedString {
    guard var result = InlineMarkdownCache.shared.parsed(source) else { return AttributedString(source) }
    // 链接使用第二强调色(与主强调色区分)
    let linkColor = OMColors.link
    for run in result.runs where run.link != nil {
        result[run.range].foregroundColor = linkColor
    }
    return result
}

/// 行内代码标记:`InlineCodeTextRenderer` 据此在文字后面画圆角底。
struct InlineCodeAttribute: TextAttribute {}

/// 行内代码渲染器:同一行里连续的、带 `InlineCodeAttribute` 的片段(含两侧内边距空格,系统会把它们拆成独立片段)
/// 合并成一个矩形,只画一块圆角底(圆角取 `OMRadius.tag`);先画全部底色,再画文字。
/// 底色矩形 = 合并后的排版框,不再额外上下外扩,使上下左右四边留白一致;跨行换行的代码每行各一块。
struct InlineCodeTextRenderer: TextRenderer {
    /// 底色
    var fill: Color
    /// 圆角
    var radius: CGFloat

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            var group: CGRect?
            for run in line {
                if run[InlineCodeAttribute.self] != nil {
                    let rect = run.typographicBounds.rect
                    group = group.map { $0.union(rect) } ?? rect
                } else if let finished = group {
                    fillBackground(finished, in: &context)
                    group = nil
                }
            }
            if let finished = group { fillBackground(finished, in: &context) }
            for run in line { context.draw(run) }
        }
    }

    /// 画一块圆角底。
    private func fillBackground(_ rect: CGRect, in context: inout GraphicsContext) {
        context.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(fill))
    }
}

/// 行内代码两侧的内边距字符:发丝空格(U+200A,约 0.2em),与排版框上下的留白视觉相当。
private let inlineCodePadding = "\u{200A}"

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
            piece = Text(verbatim: "\(inlineCodePadding)\(code)\(inlineCodePadding)")
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
        case .heading, .paragraph, .list, .quote:
            // 正常路径由 `MarkdownSegment` 合并为文字段;这里仅作兜底
            MarkdownTextRunView(blocks: [block])
        case .code(let language, let code, let isClosed):
            // 围栏闭合后才渲染 Mermaid,避免流式输出中途反复解析失败
            if isClosed, language?.lowercased() == "mermaid", let chart = ChartFence.parseXY(code) {
                // MermaidKit 不支持 xychart-beta:转成原生图表
                ChartFenceView(chart: chart)
            } else if isClosed, language?.lowercased() == "mermaid" {
                MermaidBlockView(source: code)
            } else if isClosed, language?.lowercased() == "chart", let chart = ChartFence.parse(code) {
                // 围栏闭合且 JSON 合法才画图;否则回退为普通代码块
                ChartFenceView(chart: chart)
            } else {
                CodeBlockView(language: language, code: code)
            }
        case .table(let header, let rows):
            TableBlockView(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
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
            // 正文由 AppKit 文本叶子渲染(原生选择、整块一个文本视图、按需折行或叶子内水平滚动)
            CodeTextLeaf(language: language, code: code, wrap: wrapLines)
        }
        .omSolidCard()
    }
}

/// 表格块:正文由 AppKit 文本叶子渲染(制表位对齐、可跨行选择、复制为制表符分隔文本)。
struct TableBlockView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        TableTextLeaf(header: header, rows: rows)
            .omSolidCard()
    }
}
