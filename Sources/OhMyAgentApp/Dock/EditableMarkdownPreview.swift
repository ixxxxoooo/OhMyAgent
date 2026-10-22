// @author ixxxxoooo
// Markdown「阅读」页:样式与只读预览完全一致(复用 `MarkdownView`),点击某一块即就地切换成该块的源码编辑,
// 失焦 / Esc / 点空白处提交回文档(对齐 Cursor 的 Preview 可编辑效果,但源码始终是唯一真相,不会被重新序列化改写)。

import DesignSystem
import EditorKit
import SwiftUI

/// 可直接编辑的 Markdown 阅读页。
struct EditableMarkdownPreview: View {
    /// 当前文档全文
    let text: String
    /// 是否允许编辑(只读文件为 false)
    let isEditable: Bool
    /// 提交修改后的全文
    let onCommit: (String) -> Void

    @State private var layout = MarkdownLiveRenderer.layout(for: "")
    /// 正在编辑的块下标与其草稿
    @State private var editing: Int?
    @State private var draft = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(visibleIndices, id: \.self) { (index: Int) in
                    if editing == index {
                        BlockEditor(text: $draft, onDone: { commit() })
                    } else {
                        blockView(layout.blocks[index], index: index)
                    }
                }
                // 文末空白:点击进入末尾追加
                Color.clear.frame(height: 120).contentShape(Rectangle())
                    .onTapGesture { if editing != nil { commit() } }
                    .accessibilityHidden(true)
            }
            .environment(\.markdownDocument, true)
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
        .background(OMColors.surface)
        .task(id: text) {
            guard editing == nil else { return }
            layout = await Task.detached(priority: .userInitiated) { MarkdownLiveRenderer.layout(for: text) }.value
        }
    }

    /// 参与渲染的块下标:HTML 注释块在阅读页隐藏(与 GitHub 一致),要改请切到源码。
    private var visibleIndices: [Int] {
        layout.blocks.indices.filter { index in
            if case .htmlComment = layout.blocks[index].kind { return editing == index }
            return true
        }
    }

    /// 单块的只读渲染,点击后进入编辑。
    /// - Parameters:
    ///   - block: 块
    ///   - index: 块下标
    /// - Returns: 块视图
    @ViewBuilder
    private func blockView(_ block: MarkdownLiveBlock, index: Int) -> some View {
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
        .contentShape(Rectangle())
        .onTapGesture { begin(index, source: source) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("点击编辑此段")
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

    /// 进入某块的编辑(先提交正在编辑的块)。
    private func begin(_ index: Int, source: String) {
        guard isEditable else { return }
        if editing != nil { commit() }
        // 提交可能改变块数量,按文本重新定位
        guard index < layout.blocks.count else { return }
        draft = source.hasSuffix("\n") ? String(source.dropLast()) : source
        editing = index
    }

    /// 把草稿写回文档并重新布局。
    private func commit() {
        guard let index = editing, index < layout.blocks.count else { editing = nil; return }
        let range = layout.blocks[index].range
        let original = slice(range)
        let trailing = original.hasSuffix("\n") ? "\n" : ""
        let replaced = draft.trimmingCharacters(in: .newlines) + trailing
        editing = nil
        guard replaced != original else { return }
        let ns = text as NSString
        let next = ns.replacingCharacters(in: range, with: replaced)
        onCommit(next)
        layout = MarkdownLiveRenderer.layout(for: next)
    }
}

/// 块源码编辑器:等宽字体、随内容自动增高;失焦或 Esc 结束。
private struct BlockEditor: View {
    @Binding var text: String
    let onDone: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 隐形文本撑出高度(TextEditor 自身不会随内容增高)
            Text(text + "\n").font(OMFonts.mono).opacity(0).padding(.horizontal, 5).padding(.vertical, 8)
            TextEditor(text: $text)
                .font(OMFonts.mono)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .onExitCommand { onDone() }
        }
        .padding(2)
        .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).stroke(OMColors.accent.opacity(0.5), lineWidth: 1))
        .onAppear { focused = true }
        .onChange(of: focused) { _, now in if !now { onDone() } }
    }
}
