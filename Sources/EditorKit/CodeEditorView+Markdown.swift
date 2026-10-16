// @author ygw
// Markdown 在编辑器里的渲染:把 `MarkdownLiveRenderer` 的块布局落成文本属性。
// - 就地渲染(live):标题放大、加粗/斜体/删除线/行内代码/链接按样式显示,语法标记符在光标所在块以外折叠,
//   光标进入某块时该块还原为带淡色标记符的源码(Typora 式)。
// - 源码着色(source):保持等宽源码,只对标题/标记符/代码/链接着色。
// 只改文本属性(不改字符),不会触发 textDidChange 与撤销登记。

import AppKit

/// 编辑器里 Markdown 的显示模式。
public enum MarkdownEditorMode: Sendable, Equatable {
    /// 不特殊处理(按普通语言走词法高亮)
    case off
    /// 等宽源码 + 着色
    case source
    /// 就地渲染
    case live
}

/// Markdown 渲染的运行状态。
struct MarkdownRenderState {
    /// 最近一次与当前文本一致的块布局;编辑后失效为 nil
    var layout: MarkdownLiveLayout?
    /// 当前活动块(光标所在)
    var activeBlock: Int?
    var task: Task<Void, Never>?
    /// 正在写入属性(避免选区回调递归)
    var isApplying = false
}

extension CodeEditorView {
    /// 超过该长度的 Markdown 退化为源码着色(逐块写属性的成本随长度线性增长)。
    static let liveMaxLength = 150_000

    /// 当前是否由 Markdown 块布局接管着色。
    var usesMarkdownStyling: Bool { language == .markdown && markdownMode != .off }

    /// 实际生效的模式(超长文本把 live 降级为 source)。
    private var effectiveMarkdownMode: MarkdownEditorMode {
        guard markdownMode == .live else { return markdownMode }
        return (textView.string as NSString).length > Self.liveMaxLength ? .source : .live
    }

    // MARK: 模式切换与调度

    func markdownModeDidChange() {
        markdown.task?.cancel()
        markdown.layout = nil
        markdown.activeBlock = nil
        if usesMarkdownStyling {
            scheduleMarkdownRender(delay: .zero)
        } else {
            clearMarkdownStyling()
            highlightedRange = NSRange(location: 0, length: 0)
            scheduleHighlight()
        }
    }

    /// 在后台解析并回到主线程落属性;重复调用只保留最后一次。
    func scheduleMarkdownRender(delay: Duration) {
        markdown.task?.cancel()
        guard usesMarkdownStyling else { return }
        let text = textView.string
        let current = generation
        markdown.task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let layout = await Task.detached(priority: .userInitiated) { MarkdownLiveRenderer.layout(for: text) }.value
            guard !Task.isCancelled, let self, self.generation == current, self.usesMarkdownStyling else { return }
            self.applyMarkdown(layout)
        }
    }

    // MARK: 落属性

    /// 全量应用:先铺基础属性,再逐块着色。
    private func applyMarkdown(_ layout: MarkdownLiveLayout) {
        guard let storage = textView.textStorage, storage.length == layout.length else { return }
        markdown.isApplying = true
        defer { markdown.isApplying = false }
        let mode = effectiveMarkdownMode
        let selection = textView.selectedRange()
        let active = mode == .live && textViewHasFocus ? layout.blockIndex(containing: selection.location) : nil
        let style = MarkdownStyler(theme: theme, mode: mode)
        storage.beginEditing()
        storage.setAttributes(style.baseAttributes, range: NSRange(location: 0, length: storage.length))
        for (index, block) in layout.blocks.enumerated() {
            style.apply(block, active: index == active, to: storage)
        }
        storage.endEditing()
        markdown.layout = layout
        markdown.activeBlock = active
        textView.typingAttributes = style.baseAttributes
    }

    /// 清除 Markdown 样式,恢复编辑器默认文本属性。
    private func clearMarkdownStyling() {
        guard let storage = textView.textStorage else { return }
        markdown.isApplying = true
        defer { markdown.isApplying = false }
        let attributes: [NSAttributedString.Key: Any] = [.font: theme.font, .foregroundColor: theme.foreground]
        storage.beginEditing()
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.typingAttributes = attributes
    }

    // MARK: 活动块

    /// 文本视图是否持有键盘焦点(无焦点时所有块都按渲染态显示)。
    var textViewHasFocus: Bool { textView.window?.firstResponder === textView }

    /// 光标移动或焦点变化:若活动块变了则只重写新旧两个块(live 模式)。
    func markdownSelectionDidChange(focus: Bool? = nil) {
        guard markdownMode == .live, effectiveMarkdownMode == .live, !markdown.isApplying,
              let layout = markdown.layout, let storage = textView.textStorage, storage.length == layout.length else { return }
        let hasFocus = focus ?? textViewHasFocus
        let next = hasFocus ? layout.blockIndex(containing: textView.selectedRange().location) : nil
        guard next != markdown.activeBlock else { return }
        let previous = markdown.activeBlock
        markdown.activeBlock = next
        markdown.isApplying = true
        defer { markdown.isApplying = false }
        let style = MarkdownStyler(theme: theme, mode: .live)
        storage.beginEditing()
        for index in [previous, next].compactMap({ $0 }) where layout.blocks.indices.contains(index) {
            storage.setAttributes(style.baseAttributes, range: layout.blocks[index].range)
            style.apply(layout.blocks[index], active: index == next, to: storage)
        }
        storage.endEditing()
    }

    /// 编辑前把输入属性重置为基础样式,避免新字符继承标题大小或折叠字体。
    func resetMarkdownTypingAttributes() {
        guard usesMarkdownStyling else { return }
        textView.typingAttributes = MarkdownStyler(theme: theme, mode: effectiveMarkdownMode).baseAttributes
    }
}

// MARK: - 样式表

/// 把块与片段映射为文本属性。
@MainActor
struct MarkdownStyler {
    let theme: EditorTheme
    let mode: MarkdownEditorMode

    private var isLive: Bool { mode == .live }
    private var monoSize: CGFloat { theme.font.pointSize }
    private var proseSize: CGFloat { monoSize + 1.5 }

    private var proseFont: NSFont { NSFont.systemFont(ofSize: proseSize) }
    private var monoFont: NSFont { theme.font }

    private var dimColor: NSColor { theme.gutterForeground }
    private var codeBackground: NSColor { theme.currentLine }

    /// 基础属性(正文)。
    var baseAttributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: theme.foreground]
        if isLive {
            attributes[.font] = proseFont
            attributes[.paragraphStyle] = paragraph(lineSpacing: 3.5, after: 6)
        } else {
            attributes[.font] = monoFont
        }
        return attributes
    }

    private func paragraph(lineSpacing: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0, firstIndent: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.headIndent = indent
        style.firstLineHeadIndent = firstIndent ?? indent
        return style
    }

    /// 带加粗/斜体特征的字体。
    private func font(_ base: NSFont, _ traits: MarkdownLiveTraits) -> NSFont {
        var symbolic = base.fontDescriptor.symbolicTraits
        if traits.contains(.bold) { symbolic.insert(.bold) }
        if traits.contains(.italic) { symbolic.insert(.italic) }
        guard symbolic != base.fontDescriptor.symbolicTraits else { return base }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(symbolic), size: base.pointSize) ?? base
    }

    private func headingFont(_ level: Int) -> NSFont {
        let scales: [CGFloat] = [1.75, 1.45, 1.25, 1.1, 1.0, 0.95]
        let size = proseSize * scales[min(max(level, 1), 6) - 1]
        return NSFont.systemFont(ofSize: size, weight: .bold)
    }

    /// 块的基础字体(内联特征在此之上叠加)。
    private func blockFont(_ kind: MarkdownLiveBlockKind) -> NSFont {
        guard isLive else { return monoFont }
        switch kind {
        case .heading(let level): return headingFont(level)
        case .code, .table, .frontMatter: return NSFont.monospacedSystemFont(ofSize: monoSize - 0.5, weight: .regular)
        default: return proseFont
        }
    }

    /// 给一个块写属性(先由调用方铺基础属性)。
    func apply(_ block: MarkdownLiveBlock, active: Bool, to storage: NSTextStorage) {
        let total = storage.length
        let range = NSIntersectionRange(block.range, NSRange(location: 0, length: total))
        guard range.length > 0 else { return }
        let base = blockFont(block.kind)
        applyBlockAttributes(block.kind, font: base, range: range, to: storage)
        for span in block.spans {
            let target = NSIntersectionRange(span.range, range)
            guard target.length > 0 else { continue }
            applySpan(span.style, in: target, blockFont: base, kind: block.kind, active: active, to: storage)
        }
    }

    private func applyBlockAttributes(_ kind: MarkdownLiveBlockKind, font: NSFont, range: NSRange, to storage: NSTextStorage) {
        var attributes: [NSAttributedString.Key: Any] = [:]
        switch kind {
        case .heading(let level):
            attributes[.font] = font
            if isLive {
                attributes[.paragraphStyle] = paragraph(lineSpacing: 2, before: level <= 2 ? 12 : 8, after: 4)
            } else {
                attributes[.foregroundColor] = theme.colors[.function] ?? theme.foreground
            }
        case .quote:
            attributes[.font] = font
            attributes[.foregroundColor] = isLive ? NSColor.secondaryLabelColor : dimColor
            if isLive { attributes[.paragraphStyle] = paragraph(lineSpacing: 3.5, after: 6, indent: 16) }
        case .list:
            attributes[.font] = font
            if isLive { attributes[.paragraphStyle] = paragraph(lineSpacing: 3, after: 2, indent: 20, firstIndent: 4) }
        case .code:
            attributes[.font] = font
            if isLive {
                attributes[.backgroundColor] = codeBackground
                attributes[.paragraphStyle] = paragraph(lineSpacing: 1.5, indent: 10)
            }
        case .table:
            attributes[.font] = font
            if isLive { attributes[.paragraphStyle] = paragraph(lineSpacing: 2, after: 0) }
        case .rule:
            attributes[.foregroundColor] = dimColor
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case .frontMatter:
            attributes[.font] = font
            attributes[.foregroundColor] = dimColor
        case .paragraph:
            attributes[.font] = font
        }
        if !attributes.isEmpty { storage.addAttributes(attributes, range: range) }
    }

    private func applySpan(_ style: MarkdownLiveStyle, in range: NSRange, blockFont: NSFont, kind: MarkdownLiveBlockKind, active: Bool, to storage: NSTextStorage) {
        switch style {
        case .traits(let traits):
            if !traits.intersection([.bold, .italic]).isEmpty { storage.addAttribute(.font, value: font(blockFont, traits), range: range) }
            if traits.contains(.strike) { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        case .inlineCode:
            if isLive {
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: max(blockFont.pointSize - 1.5, 9), weight: .regular),
                    .backgroundColor: codeBackground,
                    .foregroundColor: theme.colors[.string] ?? theme.foreground,
                ], range: range)
            } else {
                storage.addAttribute(.foregroundColor, value: theme.colors[.string] ?? theme.foreground, range: range)
            }
        case .link:
            storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        case .marker, .linkTail:
            if isLive, !active {
                // 折叠:极小字号 + 透明,宽度近似为零
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear], range: range)
            } else {
                storage.addAttribute(.foregroundColor, value: dimColor, range: range)
            }
        case .listMarker:
            storage.addAttributes([.foregroundColor: NSColor.controlAccentColor, .font: font(blockFont, .bold)], range: range)
        case .taskBox(let checked):
            storage.addAttributes([.foregroundColor: checked ? NSColor.systemGreen : NSColor.controlAccentColor, .font: font(blockFont, .bold)], range: range)
        case .codeToken(let token):
            if let color = theme.colors[token] { storage.addAttribute(.foregroundColor, value: color, range: range) }
        case .dim:
            storage.addAttribute(.foregroundColor, value: dimColor, range: range)
        case .tableHeader:
            storage.addAttribute(.font, value: font(blockFont, .bold), range: range)
        }
    }
}
