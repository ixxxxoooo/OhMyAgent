// @author ixxxxoooo
// 命令与输出的通用展示部件:shell 命令语法高亮、长输出限高滚动(可展开)。
// 做法参考 Cursor / Claude Code / Zed:输出框默认限高并内部滚动,行数多时底部给出「展开 · 共 N 行」,
// 展开后仍有上限(再长就内部滚动),运行中自动跟随末尾,复制始终复制完整输出。

import ChatKit
import DesignSystem
import EditorKit
import IconKit
import SwiftUI

/// 高亮后的 shell 命令文本(只读、可选择)。
struct ShellCommandText: View {
    let command: String
    /// 行数上限;nil 表示不限制
    var lineLimit: Int?
    /// 失败时整体染红(不再做语法着色)
    var failed = false
    var fontSize: CGFloat?
    /// 是否允许选择文字。工具行摘要要关掉:可选文字会让点击先等手势判定,点击展开会有明显延迟。
    var selectable = true

    var body: some View {
        let text = Text(failed ? AttributedString(command) : CodeHighlighter.attributed(command, language: .shell))
            .font(fontSize.map { .system(size: $0, design: .monospaced) } ?? OMFonts.monoSmall)
            .foregroundStyle(failed ? Color.red : Color.primary)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
        if selectable { text.textSelection(.enabled) } else { text }
    }
}

/// 长输出限高滚动框:短输出直接完整展示;超过阈值后限高滚动,底部提供展开/收起。
struct CollapsibleOutput: View {
    /// 原始输出(可含 ANSI;已去围栏)
    let raw: String
    var fontSize: CGFloat = 11.5
    /// 运行中:输出增长时自动滚到末尾
    var followTail = false
    /// 是否按 ANSI 解析(普通文本输出传 false,原样展示)
    var ansi = true
    @State private var expanded = false
    @State private var contentHeight: CGFloat = 0

    /// 超过该行数才启用限高滚动
    static let foldThreshold = 12
    /// 收起/展开时的最大高度
    static let collapsedHeight: CGFloat = 196
    static let expandedHeight: CGFloat = 480
    /// 最多渲染的末尾行数(更早的行只在复制时保留)
    static let renderLimit = 2000

    var body: some View {
        let slice = ToolOutputText.tail(raw, maxLines: Self.renderLimit)
        let folded = slice.totalLines > Self.foldThreshold
        VStack(alignment: .leading, spacing: 4) {
            if slice.omittedLines > 0 {
                Text("已省略前 \(slice.omittedLines) 行,仅显示末尾 \(Self.renderLimit) 行(复制可得完整输出)")
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.tertiaryText)
            }
            if folded {
                scrollingBody(slice.text)
                footer(totalLines: slice.totalLines)
            } else {
                textBody(slice.text)
            }
        }
    }

    /// 输出正文:按需解析 ANSI。
    @ViewBuilder
    private func textBody(_ text: String) -> some View {
        if ansi {
            ANSITextView(raw: text, fontSize: fontSize, maxLines: Self.renderLimit)
        } else {
            Text(text)
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 限高滚动区域:内容矮于上限时贴合内容,高于上限时滚动;收起态底部渐隐提示还有更多。
    private func scrollingBody(_ text: String) -> some View {
        let limit = expanded ? Self.expandedHeight : Self.collapsedHeight
        return ScrollViewReader { proxy in
            ScrollView {
                textBody(text)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                Color.clear.frame(height: 1).id("tail")
            }
            .frame(height: contentHeight == 0 ? limit : min(contentHeight + 1, limit))
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: raw) { if followTail { proxy.scrollTo("tail", anchor: .bottom) } }
            .onAppear { if followTail { proxy.scrollTo("tail", anchor: .bottom) } }
        }
        .overlay(alignment: .bottom) {
            if !expanded, contentHeight > Self.collapsedHeight {
                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 底部切换条:共 N 行 + 展开/收起。
    private func footer(totalLines: Int) -> some View {
        Button {
            omWithAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image.om(expanded ? "chevrons-down-up" : "chevrons-up-down", size: 10)
                Text(expanded ? String(localized: "收起") : String(localized: "展开 · 共 \(totalLines) 行"))
                    .font(OMFonts.caption)
            }
            .foregroundStyle(OMColors.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? String(localized: "收起输出") : String(localized: "展开全部输出"))
    }
}
