// @author ixxxxoooo
// 文本叶子的富文本构造器:代码(语法高亮)、终端输出(ANSI)、普通文字、Diff 块。
// 纯函数式:输入文本与样式,输出 `NSAttributedString`;令牌(字号、颜色)在调用时读取,
// 样式变化(主题、字号)由调用方通过 `OMLeafStyle` 签名触发重建。

import AppKit
import ChatKit
import DesignSystem
import DiffKit
import EditorKit
import SwiftUI

/// 影响叶子外观的全局样式签名(主题修订、明暗、字号缩放);任一变化都需要重建富文本。
struct OMLeafStyle: Hashable {
    var ui: CGFloat
    var timeline: CGFloat
    var themeRevision: Int
    var systemIsDark: Bool

    /// 当前样式快照(读取主题修订会建立 Observation 依赖,主题变化时视图自动刷新)。
    @MainActor
    static var current: OMLeafStyle {
        OMLeafStyle(ui: OMScale.ui, timeline: OMScale.timeline, themeRevision: ThemeTracker.shared.revision, systemIsDark: ThemeRuntime.systemIsDark)
    }
}

/// 叶子富文本构造器集合。
@MainActor
enum OMLeafContent {
    /// 等宽字体(随界面字号缩放)。
    /// - Parameters:
    ///   - size: 基准字号
    ///   - timeline: 是否额外乘「时间线字号」
    static func monoFont(_ size: CGFloat, timeline: Bool, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size * OMScale.ui * (timeline ? OMScale.timeline : 1), weight: weight)
    }

    // MARK: 代码

    /// 代码块的富文本:语法高亮 + 时间线代码字号与行距。
    /// - Parameters:
    ///   - code: 源码
    ///   - fence: 围栏语言标签
    /// - Returns: 富文本
    static func code(_ code: String, fence: String?) -> NSAttributedString {
        let font = monoFont(12, timeline: true)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = OMFonts.readingMonoLineSpacing
        let base = NSColor(OMColors.primaryText)
        let highlighted = CodeHighlighter.attributed(code, fence: fence)
        let result = NSMutableAttributedString()
        var colors: [Color: NSColor] = [:]
        for run in highlighted.runs {
            let text = String(highlighted[run.range].characters)
            var color = base
            if let tint = run.foregroundColor {
                if let cached = colors[tint] { color = cached } else { color = NSColor(tint); colors[tint] = color }
            }
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        return result
    }

    // MARK: 终端输出

    /// 终端输出的富文本。
    /// - Parameters:
    ///   - raw: 原始输出(`ansi` 为真时可含转义序列)
    ///   - fontSize: 基准字号
    ///   - maxLines: 只保留末尾的行数
    ///   - ansi: 是否按 ANSI 解析
    ///   - tint: 默认文字色(ANSI 显式着色的片段不受影响)
    /// - Returns: 富文本
    static func output(_ raw: String, fontSize: CGFloat, maxLines: Int, ansi: Bool, tint: NSColor) -> NSAttributedString {
        let font = monoFont(fontSize, timeline: false)
        guard ansi else {
            return NSAttributedString(string: raw, attributes: [.font: font, .foregroundColor: tint])
        }
        let bold = monoFont(fontSize, timeline: false, weight: .semibold) // ui-lint:allow 终端 ANSI 加粗属于输出内容
        let result = NSMutableAttributedString()
        // 同一份输出里不同的 ANSI 颜色很少:按 (颜色, 变暗) 缓存已转换的 NSColor。
        // 取色会读取主题调色板(拼十六进制串),逐片段都取在大输出上会卡主线程。
        var colorCache: [(color: ANSIColor, dim: Bool, value: NSColor)] = []
        func resolved(_ color: ANSIColor, dim: Bool) -> NSColor {
            if let hit = colorCache.first(where: { $0.color == color && $0.dim == dim }) { return hit.value }
            let value = NSColor(ANSITextView.color(color, dim: dim))
            colorCache.append((color, dim, value))
            return value
        }
        let secondary = NSColor(OMColors.secondaryText)
        for span in ANSIParser.parse(raw, maxLines: maxLines) {
            var attributes: [NSAttributedString.Key: Any] = [.font: span.bold ? bold : font]
            if let color = span.foreground {
                attributes[.foregroundColor] = resolved(color, dim: span.dim)
            } else {
                attributes[.foregroundColor] = span.dim ? secondary : tint
            }
            if span.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: span.text, attributes: attributes))
        }
        return result
    }

    // MARK: 普通文字

    /// 普通文字的富文本(用户消息、思考、提示)。
    /// - Parameters:
    ///   - text: 文本
    ///   - size: 基准字号(时间线字号会额外缩放)
    ///   - color: 文字色
    ///   - timeline: 是否乘「时间线字号」
    static func prose(_ text: String, size: CGFloat, color: NSColor, timeline: Bool = true) -> NSAttributedString {
        let scaled = size * OMScale.ui * (timeline ? OMScale.timeline : 1)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = OMFonts.lineSpacing(forSize: scaled)
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: scaled), .foregroundColor: color, .paragraphStyle: style])
    }

    /// 用户消息正文:其中的文件/文件夹引用(`@路径`)渲染成与输入框一致的 chip,复制时还原为记号。
    /// - Parameters:
    ///   - text: 消息文本
    ///   - workspace: 工作区目录(相对路径基准;用于判断引用是否存在)
    ///   - size: 基准字号
    ///   - color: 文字色
    ///   - timeline: 是否乘「时间线字号」
    ///   - exists: 路径存在性判断(测试可注入)
    /// - Returns: 富文本;无有效引用时与 `prose` 相同
    static func userMessage(
        _ text: String, workspace: URL, size: CGFloat, color: NSColor, timeline: Bool = true,
        exists: (String) -> Bool? = FileMentions.fileSystemExists
    ) -> NSAttributedString {
        let plain = prose(text, size: size, color: color, timeline: timeline)
        guard text.contains("@") else { return plain }
        let pieces = ComposerMentionLayout.pieces(for: text, workspace: workspace, allowTrailingEnd: true, exists: exists)
        guard pieces.contains(where: { if case .mention = $0 { true } else { false } }) else { return plain }
        let attributes = plain.attributes(at: 0, effectiveRange: nil)
        return MentionChipImage.attributedString(pieces: pieces, attributes: attributes)
    }

    // MARK: 表格

    /// 单元格文字区最小宽度(再短的内容也不窄于此)。
    static let tableMinColumn: CGFloat = 40
    /// 单元格文字区最大宽度:超过则在单元格内折行(与 GitHub/Typora 的「长文本折行、整表可横向滚动」一致)。
    static let tableMaxColumn: CGFloat = 360

    /// 一张表的列宽方案:每列的文字区宽度与整表总宽(含单元格内边距)。
    struct TableMetrics: Equatable {
        /// 每列文字区宽度
        var columnWidths: [CGFloat]
        /// 单元格左右内边距(单侧)
        var horizontalPadding: CGFloat
        /// 整表总宽(各列文字区 + 两侧内边距之和)
        var totalWidth: CGFloat { columnWidths.reduce(0) { $0 + $1 + horizontalPadding * 2 } }
    }

    /// 由各列单元格的自然(单行)宽度算出列宽方案:夹在 [最小, 最大] 之间,留 2pt 余量避免因取整被意外折行。
    /// - Parameters:
    ///   - naturalWidths: 每列最宽单元格的单行宽度
    ///   - horizontalPadding: 单元格左右内边距(单侧)
    /// - Returns: 列宽方案
    static func tableMetrics(naturalWidths: [CGFloat], horizontalPadding: CGFloat) -> TableMetrics {
        TableMetrics(
            columnWidths: naturalWidths.map { min(max(ceil($0) + 2, tableMinColumn), tableMaxColumn) },
            horizontalPadding: horizontalPadding
        )
    }

    /// 表格的富文本:用 `NSTextTable` 排版(与 TextEdit/邮件同一套原生表格引擎),每个单元格是真正的表格单元:
    /// 列宽统一测量一次(表头与各行共用)、过长内容在单元格内折行、表头有底色、行间有发丝分隔线、按列对齐。
    /// 复制选区即得到「制表符 + 换行」分隔的文本(每个单元格结尾的换行在复制时还原为制表符/换行)。
    /// - Parameters:
    ///   - header: 表头
    ///   - rows: 数据行
    ///   - aligns: 每列对齐(缺省按左对齐)
    ///   - roomy: 宽松排版(文档阅读页:内边距更大)
    /// - Returns: 富文本
    static func table(header: [String], rows: [[String]], aligns: [MarkdownTableAlign] = [], roomy: Bool = false) -> NSAttributedString {
        // 文档排版(整页阅读):字号与会话一致,只放宽单元格内边距
        let size = 11.5 * OMScale.ui
        let padH: CGFloat = roomy ? 14 : 10
        let padV: CGFloat = roomy ? 8 : 5
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return NSAttributedString() }
        let headerCells = (0..<columns).map { tableCell($0 < header.count ? header[$0] : "", size: size, weight: .medium) }
        let bodyCells = rows.map { row in (0..<columns).map { tableCell($0 < row.count ? row[$0] : "", size: size, weight: .regular) } }
        // 列宽:每列所有单元格(含表头)的单行自然宽度取最大
        var natural = [CGFloat](repeating: 0, count: columns)
        for line in [headerCells] + bodyCells {
            for (index, text) in line.enumerated() {
                let width = text.length == 0 ? 0 : text.boundingRect(with: NSSize(width: 100_000, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).width
                natural[index] = max(natural[index], width)
            }
        }
        let metrics = tableMetrics(naturalWidths: natural, horizontalPadding: padH)
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(metrics.totalWidth, type: .absoluteValueType)

        let lineColor = NSColor(OMColors.hairline)
        let headerFill = NSColor(OMColors.subtleFill)
        let result = NSMutableAttributedString()
        let allLines = [headerCells] + bodyCells
        for (row, line) in allLines.enumerated() {
            let isHeader = row == 0
            let isLastRow = row == allLines.count - 1
            for (column, text) in line.enumerated() {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setContentWidth(metrics.columnWidths[column], type: .absoluteValueType)
                block.setWidth(padH, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(padH, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(padV, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(padV, type: .absoluteValueType, for: .padding, edge: .maxY)
                if !isLastRow {
                    block.setWidth(isHeader ? 1 : 0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                    block.setBorderColor(lineColor, for: .maxY)
                }
                if isHeader { block.backgroundColor = headerFill }
                block.verticalAlignment = .topAlignment

                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.lineBreakMode = .byWordWrapping
                style.alignment = alignment(aligns.indices.contains(column) ? aligns[column] : .none)
                let piece = NSMutableAttributedString(attributedString: text)
                // 每个单元格以换行结尾(NSTextTable 要求一个单元格一个段落);复制时换行还原为制表符/行尾换行
                let isLast = isLastRow && column == columns - 1
                let terminator = NSAttributedString(string: "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: size), OMReadOnlyTextView.copyTextKey: isLast ? "" : (column == columns - 1 ? "\n" : "\t"),
                ])
                piece.append(terminator)
                piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
                result.append(piece)
            }
        }
        result.addAttribute(omIntrinsicWidthKey, value: metrics.totalWidth, range: NSRange(location: 0, length: 1))
        return result
    }

    /// Markdown 列对齐 → 段落对齐。
    private static func alignment(_ align: MarkdownTableAlign) -> NSTextAlignment {
        switch align {
        case .center: return .center
        case .right: return .right
        case .left, .none: return .left
        }
    }

    /// 表格单元格:行内 Markdown(粗体、斜体、删除线、链接、行内代码)→ 富文本。
    private static func tableCell(_ source: String, size: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
        let parsed = inlineMarkdown(source)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            let text = String(parsed[run.range].characters).replacingOccurrences(of: "\n", with: " ")
            if intent.contains(.code) {
                result.append(NSAttributedString(string: text, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: NSColor(OMColors.accentText),
                ]))
                continue
            }
            var font = NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(OMColors.primaryText)]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link; attributes[.foregroundColor] = NSColor(OMColors.link) }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    // MARK: Diff

    /// Diff 行号槽总宽度(含色条与两侧内边距)与单列宽度、符号列宽度。
    static let gutterWidth: CGFloat = 76
    static let gutterColumn: CGFloat = 34
    static let signWidth: CGFloat = 18

    /// 一组 Diff 行的富文本:正文是纯代码文本,行号、符号与底色由布局管理器绘制(复制只得到正文)。
    /// - Parameters:
    ///   - lines: 行(并排视图里没有对应行的一侧为 nil,按空行占位)
    ///   - marks: 与 `lines` 等长的行内变化区间(`Character` 偏移)
    ///   - twoColumns: 是否画新旧两列行号;`false` 时只画 `side` 指定的一列
    ///   - side: 并排视图的哪一侧
    /// - Returns: 富文本
    static func diff(_ lines: [DiffLine?], marks: [Range<Int>?], twoColumns: Bool, side: DiffSide = .both) -> NSAttributedString {
        let font = monoFont(11, timeline: false)
        let gutterFont = font
        let result = NSMutableAttributedString()
        var fills: [OMDiffPalette.Kind: NSColor] = [:]
        func fill(_ kind: OMDiffPalette.Kind) -> NSColor {
            if let cached = fills[kind] { return cached }
            let color = NSColor(OMDiffPalette.background(kind))
            fills[kind] = color
            return color
        }
        let gutterWidth = twoColumns ? Self.gutterWidth : Self.gutterWidth - Self.gutterColumn
        let indent = gutterWidth + Self.signWidth
        for (index, entry) in lines.enumerated() {
            let kind = paletteKind(entry)
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            let textColor = NSColor(entry?.kind == .context ? OMColors.secondaryText : OMColors.primaryText)
            let source = entry.map { $0.text.isEmpty ? " " : DiffSoftLimit.displayText($0.text) } ?? " "
            let piece = NSMutableAttributedString(string: source + (index == lines.count - 1 ? "" : "\n"), attributes: [
                .font: font, .foregroundColor: textColor, .paragraphStyle: style, omLineFillKey: fill(kind),
                omGutterKey: gutterInfo(entry, kind: kind, width: gutterWidth, font: gutterFont, twoColumns: twoColumns, side: side),
            ])
            if let entry, entry.kind != .context, index < marks.count, let mark = marks[index], mark.lowerBound < mark.upperBound {
                let characters = Array(source)
                if mark.upperBound <= characters.count {
                    let from = source.index(source.startIndex, offsetBy: mark.lowerBound)
                    let to = source.index(source.startIndex, offsetBy: mark.upperBound)
                    let tint = (entry.kind == .added ? OMColors.diffAdded : OMColors.diffRemoved).opacity(0.38)
                    piece.addAttribute(.backgroundColor, value: NSColor(tint), range: NSRange(from..<to, in: source))
                }
            }
            result.append(piece)
        }
        return result
    }

    /// 并排视图的哪一侧(决定显示哪一列行号)。
    enum DiffSide { case both, old, new }

    private static func paletteKind(_ line: DiffLine?) -> OMDiffPalette.Kind {
        guard let line else { return .empty }
        switch line.kind {
        case .added: return .added
        case .removed: return .removed
        case .context: return .context
        }
    }

    private static func gutterInfo(_ line: DiffLine?, kind: OMDiffPalette.Kind, width: CGFloat, font: NSFont, twoColumns: Bool, side: DiffSide) -> OMGutterInfo {
        let sign: String
        switch line?.kind {
        case .added: sign = "+"
        case .removed: sign = "−"
        default: sign = ""
        }
        let old = line?.oldNumber.map(String.init) ?? ""
        let new = line?.newNumber.map(String.init) ?? ""
        let single = side == .old ? old : new
        return OMGutterInfo(
            oldNumber: old, newNumber: twoColumns ? new : single, sign: sign, width: width, columnWidth: gutterColumn,
            fill: NSColor(OMDiffPalette.gutter(kind)), bar: NSColor(OMDiffPalette.bar(kind)),
            numberColor: NSColor(OMColors.tertiaryText), signColor: NSColor(OMColors.primaryText), font: font, twoColumns: twoColumns)
    }
}
