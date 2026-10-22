// @author ixxxxoooo
// Markdown「阅读」页(只读):按 `MarkdownLive` 的块划分逐块渲染,样式与会话里的 Markdown 一致(复用 `MarkdownView`);
// 前置元数据显示为属性卡片,HTML 注释块隐藏。要修改内容请切到「源码」。

import DesignSystem
import EditorKit
import SwiftUI

/// 只读的 Markdown 阅读页。
struct MarkdownPreviewPage: View {
    /// 当前文档全文
    let text: String

    @State private var layout = MarkdownLiveRenderer.layout(for: "")

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(visibleIndices, id: \.self) { (index: Int) in
                    blockView(layout.blocks[index])
                }
                // 文末留白,最后一块不贴着窗口底边
                Color.clear.frame(height: 120).accessibilityHidden(true)
            }
            .environment(\.markdownDocument, true)
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
        .background(OMColors.surface)
        .task(id: text) {
            layout = await Task.detached(priority: .userInitiated) { MarkdownLiveRenderer.layout(for: text) }.value
        }
    }

    /// 参与渲染的块下标:HTML 注释块在阅读页隐藏(与 GitHub 一致)。
    private var visibleIndices: [Int] {
        layout.blocks.indices.filter { index in
            if case .htmlComment = layout.blocks[index].kind { return false }
            return true
        }
    }

    /// 单块的只读渲染。
    /// - Parameter block: 块
    /// - Returns: 块视图
    @ViewBuilder
    private func blockView(_ block: MarkdownLiveBlock) -> some View {
        let source = slice(block.range)
        Group {
            if case .frontMatter = block.kind {
                if let fields = FrontMatterParser.parse(source) {
                    FrontMatterCard(fields: fields)
                } else {
                    // 嵌套/多行等复杂 YAML 解析不了:退回等宽源码,不丢信息
                    Text(source.trimmingCharacters(in: .newlines)).font(OMFonts.monoSmall).foregroundStyle(OMColors.tertiaryText)
                }
            } else {
                MarkdownView(text: source)
            }
        }
        // 每块单独排版,文本视图首段的「段前距」会被忽略:标题上方的留白在这里补上(与整页阅读一致)
        .padding(.top, headingGap(block.kind))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 标题块上方额外留白(块间距 16 之外补足到 28 / 20)。
    /// - Parameter kind: 块种类
    /// - Returns: 额外上边距
    private func headingGap(_ kind: MarkdownLiveBlockKind) -> CGFloat {
        guard case .heading(let level) = kind else { return 0 }
        return level <= 2 ? 12 : 4
    }

    /// 取文档中某范围的文本。
    /// - Parameter range: UTF-16 范围
    /// - Returns: 子串;越界返回空串
    private func slice(_ range: NSRange) -> String {
        let ns = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return "" }
        return ns.substring(with: range)
    }
}
