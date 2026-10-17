// @author ixxxxoooo
// Markdown 文字段:把相邻的标题/段落/列表/引用合并成一个 AppKit 只读文本视图(NSTextView),
// 使鼠标可以跨段落、跨列表项连续拖选并一次复制(SwiftUI 的 textSelection 只能在单个 Text 内选择)。
// 行内代码圆角底与引用竖条由自定义 NSLayoutManager 绘制。

import AppKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 行内代码标记(值为 `true`):布局管理器据此在文字后画圆角底。
private let omInlineCodeKey = NSAttributedString.Key("OMInlineCode")
/// 引用块标记(值为 `true`):布局管理器据此在左侧画竖条。
private let omQuoteKey = NSAttributedString.Key("OMQuote")
/// 软换行占位:用 U+2028(行分隔符)代替 `\n`,使同一段落内的换行不触发段间距;复制时还原。
private let softBreak = "\u{2028}"
/// 行内代码两侧的内边距字符:四分之一个全角空格(U+2005)。
private let codePadding = "\u{2005}"

/// 是否属于「文字段」的块(可合并进同一个文本视图)。
/// - Parameter block: Markdown 块
/// - Returns: 标题、段落、列表、引用为 true
func isTextRunBlock(_ block: MarkdownBlock) -> Bool {
    switch block {
    case .heading, .paragraph, .list, .quote: return true
    case .code, .table, .rule: return false
    }
}

/// 一段连续文字块对应的富文本构造器。
@MainActor
enum MarkdownTextRunBuilder {
    /// 构造富文本;令牌(字号、颜色)在调用时读取,主题或字号变化时随视图刷新重建。
    /// - Parameter blocks: 连续的文字块(标题/段落/列表/引用)
    /// - Returns: 富文本
    static func build(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let scale = OMScale.ui * OMScale.timeline
        let bodySize = 13 * scale
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            switch block {
            case .heading(let level, let text):
                let size = headingSize(level) * scale
                let style = paragraphStyle(size: size, before: level <= 2 ? 6 : 2, after: 10)
                result.append(inline(text, size: size, weight: .medium, color: NSColor(OMColors.primaryText), style: style))
            case .paragraph(let text):
                let style = paragraphStyle(size: bodySize, before: 0, after: 10)
                result.append(inline(text, size: bodySize, weight: .regular, color: NSColor(OMColors.primaryText), style: style))
            case .quote(let text):
                let style = paragraphStyle(size: bodySize, before: 0, after: 10, indent: 13)
                let quote = NSMutableAttributedString(attributedString: inline(
                    text, size: bodySize, weight: .regular, color: NSColor(OMColors.secondaryText), style: style))
                quote.addAttribute(omQuoteKey, value: true, range: NSRange(location: 0, length: quote.length))
                result.append(quote)
            case .list(let items):
                for (itemIndex, item) in items.enumerated() {
                    if itemIndex > 0 { result.append(NSAttributedString(string: "\n")) }
                    result.append(listItem(item, size: bodySize, last: itemIndex == items.count - 1))
                }
            case .code, .table, .rule:
                break
            }
        }
        return result
    }

    /// 标题字号(基准,未缩放)。
    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15
        default: return 14
        }
    }

    /// 段落样式:行高为字号 1.5 倍(与 `OMFonts.lineSpacing` 校准一致)。
    private static func paragraphStyle(size: CGFloat, before: CGFloat, after: CGFloat, indent: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = OMFonts.lineSpacing(forSize: size)
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    /// 单个列表项:缩进 + 标记 + 制表位对齐,折行后文字与首行文字左对齐。
    private static func listItem(_ item: MarkdownListItem, size: CGFloat, last: Bool) -> NSAttributedString {
        let indent = CGFloat(item.level) * 16
        let font = NSFont.systemFont(ofSize: size)
        let markerColor = NSColor(item.checked == true ? OMColors.accent : OMColors.secondaryText)
        let marker = NSMutableAttributedString()
        var markerWidth: CGFloat
        if let checked = item.checked {
            let icon = NSTextAttachment()
            let image = tinted(OMIconRenderer.nsImage(checked ? "checkmark.square.fill" : "square", size: 12 * OMScale.ui), color: markerColor)
            icon.image = image
            icon.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
            marker.append(NSAttributedString(attachment: icon))
            markerWidth = image.size.width
        } else {
            marker.append(NSAttributedString(string: item.marker, attributes: [.font: font, .foregroundColor: markerColor]))
            markerWidth = (item.marker as NSString).size(withAttributes: [.font: font]).width
        }
        markerWidth += 6
        let style = paragraphStyle(size: size, before: 0, after: last ? 10 : 4)
        style.firstLineHeadIndent = indent
        style.headIndent = indent + markerWidth
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
        style.defaultTabInterval = markerWidth
        let line = NSMutableAttributedString()
        line.append(marker)
        line.append(NSAttributedString(string: "\t", attributes: [.font: font]))
        line.append(inline(item.text, size: size, weight: .regular, color: NSColor(OMColors.primaryText), style: style))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    /// 给模板图标着色。
    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// 行内 Markdown → 富文本:粗体、斜体、删除线、链接、行内代码(等宽 + 强调色 + 两侧内边距 + 圆角底标记)。
    private static func inline(_ source: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                               style: NSParagraphStyle) -> NSAttributedString {
        let parsed = inlineMarkdown(source)
        let result = NSMutableAttributedString()
        let codeSize = 12 * OMScale.ui * OMScale.timeline
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            let text = String(parsed[run.range].characters).replacingOccurrences(of: "\n", with: softBreak)
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
                attributes[.foregroundColor] = NSColor(OMColors.accentText)
                attributes[omInlineCodeKey] = true
                result.append(NSAttributedString(string: codePadding + text + codePadding, attributes: attributes))
                continue
            }
            var font = NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            attributes[.font] = font
            attributes[.foregroundColor] = color
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }
}

/// 布局管理器:在文字下方画行内代码圆角底与引用竖条。
final class MarkdownLayoutManager: NSLayoutManager {
    /// 行内代码底色
    var codeFill = NSColor.clear
    /// 引用竖条颜色
    var quoteBar = NSColor.clear

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(omInlineCodeKey, in: charRange) { value, range, _ in
            guard value != nil else { return }
            drawCodeBackground(characterRange: range, origin: origin, storage: storage)
        }
        storage.enumerateAttribute(omQuoteKey, in: charRange) { value, range, _ in
            guard value != nil else { return }
            drawQuoteBar(characterRange: range, origin: origin)
        }
    }

    /// 逐行画一块圆角底;高度取字体排版框(ascender + |descender|),使上下左右留白一致。
    private func drawCodeBackground(characterRange: NSRange, origin: NSPoint, storage: NSTextStorage) {
        let glyphRange = self.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard let font = storage.attribute(.font, at: characterRange.location, effectiveRange: nil) as? NSFont else { return }
        enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, container, lineGlyphs, _ in
            let sub = NSIntersectionRange(lineGlyphs, glyphRange)
            guard sub.length > 0 else { return }
            let bounds = self.boundingRect(forGlyphRange: sub, in: container)
            let baseline = fragment.minY + self.location(forGlyphAt: sub.location).y
            let rect = CGRect(x: bounds.minX, y: baseline - font.ascender, width: bounds.width, height: font.ascender - font.descender)
                .offsetBy(dx: origin.x, dy: origin.y)
            self.codeFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: OMRadius.tag, yRadius: OMRadius.tag).fill()
        }
    }

    /// 在引用段落左侧画 3pt 竖条(跨整个段落的所有行)。
    private func drawQuoteBar(characterRange: NSRange, origin: NSPoint) {
        let glyphRange = self.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        var top = CGFloat.greatestFiniteMagnitude
        var bottom = -CGFloat.greatestFiniteMagnitude
        enumerateLineFragments(forGlyphRange: glyphRange) { _, used, _, _, _ in
            top = min(top, used.minY)
            bottom = max(bottom, used.maxY)
        }
        guard top < bottom else { return }
        let rect = CGRect(x: origin.x, y: top + origin.y, width: 3, height: bottom - top)
        quoteBar.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill() // ui-lint:allow 引用条细线圆角
    }
}

/// 只读可选的 Markdown 文本视图:复制时把软换行占位还原为 `\n`。
final class MarkdownTextView: NSTextView {
    /// 文本存储由外部创建(NSTextView 不持有它),这里强引用以防被释放。
    var retainedStorage: NSTextStorage?

    override func copy(_ sender: Any?) {
        let selected = selectedRange()
        guard selected.length > 0 else { return }
        let plain = (string as NSString).substring(with: selected).replacingOccurrences(of: softBreak, with: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
    }

    /// 鼠标在视图外松开前仍由本视图接管拖选;滚轮交给外层 SwiftUI 滚动视图。
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// 把富文本放进 `MarkdownTextView`,按建议宽度自适应高度。
struct MarkdownTextRepresentable: NSViewRepresentable {
    let content: NSAttributedString
    let codeFill: NSColor
    let quoteBar: NSColor
    let linkColor: NSColor
    let selectionColor: NSColor

    func makeNSView(context: Context) -> MarkdownTextView { Self.makeTextView() }

    /// 创建 TextKit 1 文本视图(自定义布局管理器画行内代码底与引用条)。
    /// - Returns: 只读可选的文本视图
    static func makeTextView() -> MarkdownTextView {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = MarkdownTextView(frame: .zero, textContainer: container)
        view.retainedStorage = storage
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.focusRingType = .none
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setAccessibilityLabel(String(localized: "消息正文"))
        return view
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        if let layout = view.layoutManager as? MarkdownLayoutManager {
            layout.codeFill = codeFill
            layout.quoteBar = quoteBar
        }
        view.linkTextAttributes = [.foregroundColor: linkColor, .cursor: NSCursor.pointingHand]
        view.selectedTextAttributes = [.backgroundColor: selectionColor]
        guard let storage = view.textStorage, !storage.isEqual(to: content) else {
            view.needsDisplay = true
            return
        }
        let selected = view.selectedRange()
        storage.setAttributedString(content)
        if selected.length > 0, NSMaxRange(selected) <= storage.length { view.setSelectedRange(selected) }
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MarkdownTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 480
        return Self.measure(view, width: width)
    }

    /// 按给定宽度排版并返回所需尺寸。
    /// - Parameters:
    ///   - view: 文本视图
    ///   - width: 可用宽度
    /// - Returns: 宽度与向上取整后的高度
    static func measure(_ view: MarkdownTextView, width: CGFloat) -> CGSize {
        guard let container = view.textContainer, let layout = view.layoutManager else { return .zero }
        if container.size.width != width { container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}

/// 一段连续文字块的视图。
struct MarkdownTextRunView: View, Equatable {
    let blocks: [MarkdownBlock]

    var body: some View {
        MarkdownTextRepresentable(
            content: MarkdownTextRunBuilder.build(blocks),
            codeFill: NSColor(OMColors.accent.opacity(0.1)),
            quoteBar: NSColor(OMColors.hairline),
            linkColor: NSColor(OMColors.link),
            selectionColor: NSColor(OMColors.accent.opacity(0.2))
        )
    }
}
