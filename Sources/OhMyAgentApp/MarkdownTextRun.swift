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
/// 行内代码两侧的内边距字符:发丝空格(U+200A)。
private let codePadding = "\u{200A}"

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
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(blockSeparator) }
            result.append(piece(block))
        }
        return result
    }

    /// 块与块之间的分隔符(一个换行,不带属性)。
    static var blockSeparator: NSAttributedString { NSAttributedString(string: "\n") }

    /// 单个块的富文本(不含块间分隔符);代码、表格、分隔线不属于文字段,返回空。
    /// - Parameter block: 文字块
    /// - Returns: 该块的富文本
    static func piece(_ block: MarkdownBlock) -> NSAttributedString {
        let scale = OMScale.ui * OMScale.timeline
        let bodySize = 13 * scale
        switch block {
        case .heading(let level, let text):
            let size = headingSize(level) * scale
            let style = paragraphStyle(size: size, before: level <= 2 ? 6 : 2, after: 10)
            return inline(text, size: size, weight: .medium, color: NSColor(OMColors.primaryText), style: style)
        case .paragraph(let text):
            let style = paragraphStyle(size: bodySize, before: 0, after: 10)
            return inline(text, size: bodySize, weight: .regular, color: NSColor(OMColors.primaryText), style: style)
        case .quote(let text):
            let style = paragraphStyle(size: bodySize, before: 0, after: 10, indent: 13)
            let quote = NSMutableAttributedString(attributedString: inline(
                text, size: bodySize, weight: .regular, color: NSColor(OMColors.secondaryText), style: style))
            quote.addAttribute(omQuoteKey, value: true, range: NSRange(location: 0, length: quote.length))
            return quote
        case .list(let items):
            let result = NSMutableAttributedString()
            for (itemIndex, item) in items.enumerated() {
                if itemIndex > 0 { result.append(blockSeparator) }
                result.append(listItem(item, size: bodySize, last: itemIndex == items.count - 1))
            }
            return result
        case .code, .table, .rule:
            return NSAttributedString()
        }
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

/// 只读可选的 Markdown 文本视图:复制时把软换行占位还原为 `\n`(见 `makeTextView` 设置的 `copyTransform`)。
/// 选择、滚轮转发等公共行为来自 `OMReadOnlyTextView`。
final class MarkdownTextView: OMReadOnlyTextView {}

/// 把一段文字块渲染进 `MarkdownTextView` 的渲染器(每个文本视图一个,作为 `NSViewRepresentable` 的协调器)。
/// 抽出来是为了让「更新文本存储」的策略可以脱离 SwiftUI 单独测试与基准。
///
/// 流式输出时每一批只会改动最后一个块(或在末尾新增块),所以:
/// 1. **按块缓存富文本**:已完成的块不再重新解析行内 Markdown、不再生成属性(`MarkdownPieceCache`);
/// 2. **尾部增量替换**:找出与上次内容相同的最长块前缀,只对文本存储里后面那部分 `replaceCharacters`,
///    TextKit 只让尾部段落失效,排版测量只重排尾部,不再整段 `setAttributedString` + 全量排版。
/// 样式(字号缩放、主题)变化时整体重建。
@MainActor
final class MarkdownTextRunRenderer {
    /// 影响富文本外观的全局样式;任一变化都使缓存与已渲染内容失效。
    struct Style: Hashable {
        var ui: CGFloat
        var timeline: CGFloat
        var themeRevision: Int
        var systemIsDark: Bool

        /// 当前样式快照。
        static var current: Style {
            Style(ui: OMScale.ui, timeline: OMScale.timeline, themeRevision: ThemeTracker.shared.revision, systemIsDark: ThemeRuntime.systemIsDark)
        }
    }

    /// 已渲染进文本存储的块(与存储内容一一对应)
    private var renderedBlocks: [MarkdownBlock] = []
    /// 各块富文本的 UTF-16 长度(不含块间分隔符)
    private var renderedLengths: [Int] = []
    /// 已渲染内容对应的样式
    private var renderedStyle: Style?
    /// 上次应用的外观签名(颜色解析为 sRGB 分量,避免每次新建的 NSColor 因身份不同而被当作变化)
    private var appliedAppearance: AppearanceSignature?
    /// 上次测量的宽度、高度与对应的内容修订(`edits`)
    private var measuredWidth: CGFloat?
    private var measuredHeight: CGFloat = 0
    private var measuredEdits = -1
    /// 实际执行排版测量的次数(测试与诊断用)
    private(set) var measurePasses = 0
    /// 实际应用外观的次数(测试与诊断用)
    private(set) var appearanceApplications = 0
    /// 实际改动文本存储的次数(测试用)
    private(set) var edits = 0
    /// 只替换尾部的增量更新次数(测试与诊断用)
    private(set) var incrementalUpdates = 0
    /// 整体重建次数(测试与诊断用)
    private(set) var fullRebuilds = 0

    /// 外观签名:四种颜色在视图当前外观下的 sRGB 分量。
    struct AppearanceSignature: Equatable {
        var codeFill: [CGFloat]
        var quoteBar: [CGFloat]
        var link: [CGFloat]
        var selection: [CGFloat]

        /// 把颜色在给定外观下解析成 RGBA 分量。
        @MainActor
        static func components(_ color: NSColor, appearance: NSAppearance) -> [CGFloat] {
            var result: [CGFloat] = [0, 0, 0, 0]
            appearance.performAsCurrentDrawingAppearance {
                let resolved = color.usingColorSpace(.sRGB) ?? color
                result = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
            }
            return result
        }
    }

    /// 应用外观(行内代码底色、引用条、链接、选区颜色);颜色没变时什么都不做。
    /// - Parameters:
    ///   - view: 目标文本视图
    ///   - codeFill: 行内代码底色
    ///   - quoteBar: 引用竖条颜色
    ///   - linkColor: 链接颜色
    ///   - selectionColor: 选区背景色
    /// - Returns: 是否真正改动了外观(并触发了重绘)
    @discardableResult
    func applyAppearance(to view: MarkdownTextView, codeFill: NSColor, quoteBar: NSColor, linkColor: NSColor, selectionColor: NSColor) -> Bool {
        let appearance = view.effectiveAppearance
        let signature = AppearanceSignature(
            codeFill: AppearanceSignature.components(codeFill, appearance: appearance),
            quoteBar: AppearanceSignature.components(quoteBar, appearance: appearance),
            link: AppearanceSignature.components(linkColor, appearance: appearance),
            selection: AppearanceSignature.components(selectionColor, appearance: appearance)
        )
        guard signature != appliedAppearance else { return false }
        appliedAppearance = signature
        appearanceApplications += 1
        if let layout = view.layoutManager as? MarkdownLayoutManager {
            layout.codeFill = codeFill
            layout.quoteBar = quoteBar
        }
        view.linkTextAttributes = [.foregroundColor: linkColor, .cursor: NSCursor.pointingHand]
        view.selectedTextAttributes = [.backgroundColor: selectionColor]
        view.needsDisplay = true
        return true
    }

    /// 测量所需尺寸,按 (宽度, 内容修订) 缓存。
    /// - Parameters:
    ///   - view: 文本视图
    ///   - proposedWidth: SwiftUI 提议的宽度;nil、0 或非有限值时沿用上次宽度(没有则用容器当前宽度),不改容器宽度
    /// - Returns: 宽度与向上取整后的高度
    func measuredSize(_ view: MarkdownTextView, proposedWidth: CGFloat?) -> CGSize {
        let proposed = proposedWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let width = proposed ?? measuredWidth ?? view.textContainer?.size.width ?? 480
        if measuredEdits == edits, measuredWidth == width { return CGSize(width: width, height: measuredHeight) }
        let size = MarkdownTextRepresentable.measure(view, width: width)
        measurePasses += 1
        measuredWidth = width
        measuredHeight = size.height
        measuredEdits = edits
        return size
    }

    /// 把 `blocks` 渲染进 `view`;内容没变时什么都不做。
    /// - Parameters:
    ///   - blocks: 连续的文字块
    ///   - view: 目标文本视图
    func apply(_ blocks: [MarkdownBlock], to view: MarkdownTextView) {
        guard let storage = view.textStorage else { return }
        let style = Style.current
        let separators = max(renderedBlocks.count - 1, 0)
        // 文本存储与记录对不上(被外部改过)时放弃增量,整体重建
        let consistent = renderedStyle == style && storage.length == renderedLengths.reduce(0, +) + separators
        let keep = consistent ? Self.commonPrefix(renderedBlocks, blocks) : 0
        if consistent, keep == blocks.count, keep == renderedBlocks.count { return }

        // 保留前缀占去的字符数:各块长度 + 块间分隔符(替换从保留前缀的末尾开始,分隔符属于被替换的部分)
        let start = renderedLengths.prefix(keep).reduce(0, +) + max(keep - 1, 0)
        let tail = NSMutableAttributedString()
        var lengths = Array(renderedLengths.prefix(keep))
        for index in keep..<blocks.count {
            if index > 0 { tail.append(MarkdownTextRunBuilder.blockSeparator) }
            // 最后一个块在流式时每批都变,缓存它只会挤掉有用的条目;其余块缓存
            let piece = index == blocks.count - 1
                ? MarkdownTextRunBuilder.piece(blocks[index])
                : MarkdownPieceCache.piece(for: blocks[index], style: style)
            tail.append(piece)
            lengths.append(piece.length)
        }

        let selected = view.selectedRange()
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
        storage.endEditing()
        if selected.length > 0, NSMaxRange(selected) <= storage.length, view.selectedRange() != selected {
            view.setSelectedRange(selected)
        }
        edits += 1
        if keep == 0 { fullRebuilds += 1 } else { incrementalUpdates += 1 }
        renderedBlocks = blocks
        renderedLengths = lengths
        renderedStyle = style
    }

    /// 两个块序列开头相同的块数。
    /// - Parameters:
    ///   - old: 上次渲染的块
    ///   - new: 本次的块
    /// - Returns: 公共前缀的块数
    static func commonPrefix(_ old: [MarkdownBlock], _ new: [MarkdownBlock]) -> Int {
        var count = 0
        let limit = min(old.count, new.count)
        while count < limit, old[count] == new[count] { count += 1 }
        return count
    }
}

/// 单个块富文本的缓存:同一个块在样式不变时只生成一次(标签切换、行被重新挂载时直接命中)。
@MainActor
enum MarkdownPieceCache {
    /// NSCache 的键:块内容 + 样式。
    private final class Key: NSObject {
        let block: MarkdownBlock
        let style: MarkdownTextRunRenderer.Style
        init(_ block: MarkdownBlock, _ style: MarkdownTextRunRenderer.Style) {
            self.block = block
            self.style = style
        }
        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(block)
            hasher.combine(style)
            return hasher.finalize()
        }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return other.style == style && other.block == block
        }
    }

    private final class Value: NSObject {
        let string: NSAttributedString
        init(_ string: NSAttributedString) { self.string = string }
    }

    private static let cache: NSCache<Key, Value> = {
        let cache = NSCache<Key, Value>()
        cache.countLimit = 1200
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    /// 命中/未命中统计(测试与诊断用)
    private(set) static var hits = 0
    private(set) static var misses = 0

    /// 取块的富文本;未命中时生成并写入。
    /// - Parameters:
    ///   - block: 文字块
    ///   - style: 当前样式
    /// - Returns: 富文本(不可变,调用方只读取/追加拷贝)
    static func piece(for block: MarkdownBlock, style: MarkdownTextRunRenderer.Style) -> NSAttributedString {
        let key = Key(block, style)
        if let hit = cache.object(forKey: key) {
            hits += 1
            return hit.string
        }
        misses += 1
        let built = MarkdownTextRunBuilder.piece(block)
        cache.setObject(Value(built), forKey: key, cost: built.length * 64)
        return built
    }

    /// 清空(测试用)。
    static func reset() {
        cache.removeAllObjects()
        hits = 0
        misses = 0
    }
}

/// 把文字块放进 `MarkdownTextView`,按建议宽度自适应高度。
struct MarkdownTextRepresentable: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    let codeFill: NSColor
    let quoteBar: NSColor
    let linkColor: NSColor
    let selectionColor: NSColor

    func makeCoordinator() -> MarkdownTextRunRenderer { MarkdownTextRunRenderer() }

    func makeNSView(context: Context) -> MarkdownTextView { Self.makeTextView() }

    /// 创建 TextKit 1 文本视图(自定义布局管理器画行内代码底与引用条)。
    /// - Returns: 只读可选的文本视图
    static func makeTextView() -> MarkdownTextView {
        let view = OMReadOnlyTextView.make(MarkdownTextView.self, layout: MarkdownLayoutManager())
        view.copyTransform = { $0.replacingOccurrences(of: softBreak, with: "\n") }
        view.setAccessibilityLabel(String(localized: "消息正文"))
        return view
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        // 外观(颜色)与内容分开处理:颜色没变就不重设链接/选区属性,也不整块重绘;
        // 内容变化时文本存储的 replaceCharacters 已让 TextKit 自行失效脏区,不需要额外 needsDisplay
        context.coordinator.applyAppearance(
            to: view, codeFill: codeFill, quoteBar: quoteBar, linkColor: linkColor, selectionColor: selectionColor)
        context.coordinator.apply(blocks, to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MarkdownTextView, context: Context) -> CGSize? {
        // 按 (宽度, 内容修订) 缓存;nil/0 提议沿用上次宽度,不改容器宽度(避免宽度来回翻转导致整段重排)
        context.coordinator.measuredSize(view, proposedWidth: proposal.width)
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
            blocks: blocks,
            codeFill: NSColor(OMColors.accent.opacity(0.1)),
            quoteBar: NSColor(OMColors.hairline),
            linkColor: NSColor(OMColors.link),
            selectionColor: NSColor(OMColors.accent.opacity(0.2))
        )
    }
}
