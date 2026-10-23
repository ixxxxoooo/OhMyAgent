// @author ixxxxoooo
// 原生编辑器的行布局:每个逻辑行一份 CoreText 排版(每个视图行一个 `CTLine`),带显示串与偏移双向映射。
// 只对视口附近的行按需排版并缓存;文本变化时按行平移/失效,不整体重排。

import AppKit
import CoreText
import DesignSystem
import EditorCore

/// 一个视图行的排版结果。
@MainActor
final class NativeRowLayout {
    /// 行内起点(UTF-16,含)。
    let start: Int
    /// 行内终点(UTF-16,不含)。
    let end: Int
    let ctLine: CTLine
    /// 排版宽度(点)。
    let width: CGFloat
    /// 显示串索引 → 行内偏移(相对 `start`);nil 表示恒等。
    private let displayToModel: [Int32]?
    /// 行内偏移(相对 `start`,长度 + 1)→ 显示串索引;nil 表示恒等。
    private let modelToDisplay: [Int32]?
    /// 显示串长度。
    let displayLength: Int

    init(start: Int, end: Int, ctLine: CTLine, width: CGFloat, displayLength: Int, displayToModel: [Int32]?, modelToDisplay: [Int32]?) {
        self.start = start
        self.end = end
        self.ctLine = ctLine
        self.width = width
        self.displayLength = displayLength
        self.displayToModel = displayToModel
        self.modelToDisplay = modelToDisplay
    }

    /// 行内偏移处的 x(相对行排版原点)。
    func x(forOffset offset: Int) -> CGFloat {
        let local = min(max(offset - start, 0), end - start)
        let display = modelToDisplay.map { Int($0[local]) } ?? local
        if display >= displayLength { return width }
        return CTLineGetOffsetForStringIndex(ctLine, display, nil)
    }

    /// x 处最近的行内偏移(落在字符前后半区分别取前/后边界)。
    func offset(forX px: CGFloat) -> Int {
        if px <= 0 { return start }
        if px >= width { return end }
        let rawIndex = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: px, y: 0))
        let display = min(max(rawIndex, 0), displayLength)
        var local = displayToModel.map { display < $0.count ? Int($0[display]) : end - start } ?? display
        local = min(max(local, 0), end - start)
        // 制表符被展开为多个空格,CoreText 只在空格边界取整:再按模型边界取最近。
        if displayToModel != nil, local < end - start {
            let left = x(forOffset: start + local)
            let right = x(forOffset: start + local + 1)
            if abs(right - px) < abs(px - left) { local += 1 }
        }
        return start + local
    }
}

/// 一个逻辑行的排版(含全部视图行)。
@MainActor
final class NativeLineLayout {
    let rows: [NativeRowLayout]
    /// 行首空白的视觉列数(制表符展开)。
    let leadingColumns: Int
    /// 整行是否只有空白(缩进参考线需要向邻行借用缩进)。
    let isBlank: Bool
    init(rows: [NativeRowLayout], leadingColumns: Int = 0, isBlank: Bool = true) {
        self.rows = rows
        self.leadingColumns = leadingColumns
        self.isBlank = isBlank
    }
}

/// 行排版构建器与缓存。
@MainActor
final class NativeLayoutCache {
    private let model: NativeEditorModel
    private let tokens: NativeTokenStore
    private(set) var font: NSFont
    private(set) var theme: EditorTheme
    /// 已按当前外观解析成具体色的前景与语法色(动态色在创建 `CTLine` 时即被固化,必须先解析)。
    private var foreground: NSColor
    private var syntaxColors: [SyntaxKind: NSColor] = [:]
    /// 彩色括号的循环色与未配对括号色。
    private var rainbow: [NSColor] = []
    private var unmatchedColor = NSColor(OMColors.danger)
    /// 括号索引(nil 或未启用则不着色)。
    weak var brackets: NativeBracketStore?
    /// 是否启用彩色括号。
    var rainbowEnabled = true
    private var entries: [Int: NativeLineLayout] = [:]
    /// 缓存上限(行)。
    static let capacity = 2_400
    /// 一个字符列的点宽(等宽字体 "0" 的步进)。
    private(set) var columnWidth: CGFloat = 8
    /// 命中与未命中计数(测试/基准)。
    private(set) var hits = 0
    private(set) var misses = 0

    init(model: NativeEditorModel, tokens: NativeTokenStore, font: NSFont, theme: EditorTheme) {
        self.model = model
        self.tokens = tokens
        self.font = font
        self.theme = theme
        foreground = theme.foreground
        columnWidth = Self.measureColumnWidth(font)
        resolveColors(appearance: NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing())
    }

    private func resolveColors(appearance: NSAppearance) {
        var resolvedForeground = theme.foreground
        var resolved: [SyntaxKind: NSColor] = [:]
        appearance.performAsCurrentDrawingAppearance {
            resolvedForeground = theme.foreground.usingColorSpace(.sRGB) ?? theme.foreground
            for (kind, color) in theme.colors { resolved[kind] = color.usingColorSpace(.sRGB) ?? color }
        }
        foreground = resolvedForeground
        syntaxColors = resolved
        var rainbowColors: [NSColor] = []
        var unmatched = NSColor(OMColors.danger)
        appearance.performAsCurrentDrawingAppearance {
            rainbowColors = [SyntaxKind.type, .function, .keyword, .number].compactMap { resolved[$0] }
            unmatched = NSColor(OMColors.danger).usingColorSpace(.sRGB) ?? NSColor(OMColors.danger)
        }
        rainbow = rainbowColors.isEmpty ? [resolvedForeground] : rainbowColors
        unmatchedColor = unmatched
    }

    static func measureColumnWidth(_ font: NSFont) -> CGFloat {
        var glyph = CGGlyph()
        var unit: UniChar = 0x30
        guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1) else { return max(font.pointSize * 0.6, 1) }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return max(advance.width, 1)
    }

    /// 更换字体与主题:整体失效。
    func update(font: NSFont, theme: EditorTheme, appearance: NSAppearance) {
        self.font = font
        self.theme = theme
        resolveColors(appearance: appearance)
        columnWidth = Self.measureColumnWidth(font)
        entries.removeAll(keepingCapacity: true)
    }

    func clear() { entries.removeAll(keepingCapacity: true) }

    /// 取某逻辑行的排版(未命中则构建)。
    func layout(forLine line: Int) -> NativeLineLayout {
        if let cached = entries[line] { hits += 1; return cached }
        misses += 1
        let built = build(line: line)
        if entries.count >= Self.capacity { trim(around: line) }
        entries[line] = built
        return built
    }

    /// 视图行的排版。
    func rowLayout(forRow row: Int) -> (layout: NativeRowLayout, line: Int, rowInLine: Int)? {
        let located = model.lineMap.locate(row: row)
        let lineLayout = layout(forLine: located.line)
        guard located.rowInLine < lineLayout.rows.count else { return lineLayout.rows.last.map { ($0, located.line, lineLayout.rows.count - 1) } }
        return (lineLayout.rows[located.rowInLine], located.line, located.rowInLine)
    }

    /// 文档变更:仅失效/平移受影响的行。
    func documentChanged(_ change: DocumentChange) {
        for edit in change.edits {
            let first = edit.startLine
            let removedLast = first + edit.removedLines
            let delta = edit.insertedLines - edit.removedLines
            if delta == 0 {
                for line in first...removedLast { entries[line] = nil }
            } else {
                var shifted: [Int: NativeLineLayout] = [:]
                shifted.reserveCapacity(entries.count)
                for (line, value) in entries {
                    if line < first { shifted[line] = value } else if line > removedLast { shifted[line + delta] = value }
                }
                entries = shifted
            }
        }
    }

    /// 保留 `line` 附近的行,清掉其余(容量超限时调用)。
    private func trim(around line: Int) {
        let keep = (line - 400)...(line + 400)
        entries = entries.filter { keep.contains($0.key) }
    }

    // MARK: 构建

    private func build(line: Int) -> NativeLineLayout {
        let rope = model.document.snapshot
        guard let range = rope.lineRange(line) else {
            return NativeLineLayout(rows: [makeRow(units: [], start: 0, end: 0, line: line, lineStartOffset: 0)])
        }
        let units = rope.slice(range)
        let points = model.wrapPoints(forLine: line)
        var rows: [NativeRowLayout] = []
        var start = 0
        for point in points + [units.count] {
            let end = min(max(point, start), units.count)
            rows.append(makeRow(units: units, start: start, end: end, line: line, lineStartOffset: range.location))
            start = end
        }
        if rows.isEmpty { rows.append(makeRow(units: units, start: 0, end: units.count, line: line, lineStartOffset: range.location)) }
        // 行首缩进列数与是否空白行(给缩进参考线用)。
        var columns = 0
        var blank = true
        let tab = max(model.metrics.tabSize, 1)
        for unit in units {
            if unit == 0x20 { columns += 1 } else if unit == 0x09 { columns += tab - columns % tab } else { blank = false; break }
        }
        return NativeLineLayout(rows: rows, leadingColumns: columns, isBlank: blank)
    }

    /// 构建一个视图行:展开制表符、替换控制字符、套语法色。
    private func makeRow(units: ContiguousArray<UInt16>, start: Int, end: Int, line: Int, lineStartOffset: Int) -> NativeRowLayout {
        let metrics = model.metrics
        var display = [UInt16]()
        display.reserveCapacity(end - start + 8)
        var needsMap = false
        // 内嵌提示:本行内(含行尾)的零宽装饰,按偏移升序。
        let inlays = inlayHints(rowStart: start, rowEnd: end, lineStartOffset: lineStartOffset, isLastRow: end == units.count)
        var inlayCursor = 0
        var inlayDisplayRanges: [NSRange] = []
        if !inlays.isEmpty { needsMap = true }
        var modelToDisplay = [Int32]()
        var displayToModel = [Int32]()
        modelToDisplay.reserveCapacity(end - start + 1)
        /// 在 `local` 处插入全部内嵌提示,返回插入前的显示下标(光标停在提示之前)。
        func emitInlays(at local: Int) -> Int? {
            var firstDisplay: Int?
            while inlayCursor < inlays.count, inlays[inlayCursor].local <= local {
                if firstDisplay == nil { firstDisplay = display.count }
                let begin = display.count
                for unit in inlays[inlayCursor].label.utf16 {
                    display.append(unit)
                    displayToModel.append(Int32(local))
                }
                inlayDisplayRanges.append(NSRange(location: begin, length: display.count - begin))
                inlayCursor += 1
            }
            return firstDisplay
        }
        var column = 0.0
        var index = start
        while index < end {
            let unit = units[index]
            var size = 1
            var scalar = UInt32(unit)
            if unit >= 0xD800, unit < 0xDC00, index + 1 < end {
                let low = units[index + 1]
                if low >= 0xDC00, low < 0xE000 {
                    scalar = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                    size = 2
                }
            }
            let local = index - start
            let hintStart = inlays.isEmpty ? nil : emitInlays(at: local)
            if unit == 0x09 {
                needsMap = true
                let spaces = max(metrics.tabSize - Int(column) % max(metrics.tabSize, 1), 1)
                modelToDisplay.append(Int32(hintStart ?? display.count))
                for _ in 0..<spaces { display.append(0x20); displayToModel.append(Int32(local)) }
                column += Double(spaces)
                index += 1
                continue
            }
            let replaced: UInt16? = (unit < 0x20 || unit == 0x7F || unit == 0x2028 || unit == 0x2029) ? 0xFFFD : nil
            for step in 0..<size {
                modelToDisplay.append(Int32(step == 0 ? (hintStart ?? display.count) : display.count))
                display.append(replaced ?? units[index + step])
                displayToModel.append(Int32(local + step))
            }
            column += metrics.width(of: scalar, atColumn: column)
            index += size
        }
        let tailHint = inlays.isEmpty ? nil : emitInlays(at: end - start)
        modelToDisplay.append(Int32(tailHint ?? display.count))
        displayToModel.append(Int32(end - start))

        let attributed = NSMutableAttributedString(string: String(decoding: display, as: UTF16.self),
                                                   attributes: [.font: font, .foregroundColor: foreground])
        applySyntax(to: attributed, rowStart: start, rowEnd: end, lineStartOffset: lineStartOffset,
                    modelToDisplay: needsMap || display.count != end - start ? modelToDisplay : nil)
        applySemantic(to: attributed, rowStart: start, rowEnd: end, lineStartOffset: lineStartOffset,
                      modelToDisplay: needsMap || display.count != end - start ? modelToDisplay : nil)
        applyBrackets(to: attributed, rowStart: start, rowEnd: end, lineStartOffset: lineStartOffset,
                      modelToDisplay: needsMap || display.count != end - start ? modelToDisplay : nil)
        if !inlayDisplayRanges.isEmpty {
            let hintColor = foreground.withAlphaComponent(0.5)
            for range in inlayDisplayRanges where NSMaxRange(range) <= attributed.length {
                attributed.addAttribute(.foregroundColor, value: hintColor, range: range)
            }
        }
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let identity = !needsMap && display.count == end - start
        return NativeRowLayout(start: start, end: end, ctLine: ctLine, width: width, displayLength: display.count,
                               displayToModel: identity ? nil : displayToModel, modelToDisplay: identity ? nil : modelToDisplay)
    }

    private func applySyntax(to text: NSMutableAttributedString, rowStart: Int, rowEnd: Int, lineStartOffset: Int, modelToDisplay: [Int32]?) {
        guard rowEnd > rowStart else { return }
        let absolute = NSRange(location: lineStartOffset + rowStart, length: rowEnd - rowStart)
        let spans = tokens.spans(intersecting: absolute)
        guard !spans.isEmpty else { return }
        let displayLength = text.length
        for span in spans {
            guard case .custom(let raw) = span.kind, let kindRaw = UInt8(exactly: raw), let kind = SyntaxKind(rawValue: kindRaw),
                  let color = syntaxColors[kind] else { continue }
            let lower = max(span.range.location - absolute.location, 0)
            let upper = min(span.range.upperBound - absolute.location, rowEnd - rowStart)
            guard upper > lower else { continue }
            let displayLower = modelToDisplay.map { Int($0[lower]) } ?? lower
            let displayUpper = modelToDisplay.map { Int($0[upper]) } ?? upper
            guard displayUpper > displayLower, displayUpper <= displayLength else { continue }
            text.addAttribute(.foregroundColor, value: color, range: NSRange(location: displayLower, length: displayUpper - displayLower))
        }
    }

    /// 取本行内的内嵌提示。
    private func inlayHints(rowStart: Int, rowEnd: Int, lineStartOffset: Int, isLastRow: Bool) -> [(local: Int, label: String)] {
        guard model.hasInlays else { return [] }
        let absolute = TextSpan(location: lineStartOffset + rowStart, length: rowEnd - rowStart)
        var result: [(local: Int, label: String)] = []
        for item in model.decorations.intersecting(absolute) where item.kind == .inlay || item.kind == .ghostText {
            let local = item.range.location - lineStartOffset - rowStart
            guard local >= 0, local <= rowEnd - rowStart, local < rowEnd - rowStart || isLastRow, var label = item.payload else { continue }
            // 幽灵补全只在光标行内联显示第一行;多行建议在末尾加省略号提示还有后续
            if item.kind == .ghostText, let newline = label.firstIndex(of: "\n") { label = String(label[..<newline]) + " …" }
            result.append((local, label))
        }
        result.sort { $0.local < $1.local }
        return result
    }

    /// 语义着色:语言服务器给出的标记覆盖语法色(仅覆盖有对应语法类别的标记)。
    private func applySemantic(to text: NSMutableAttributedString, rowStart: Int, rowEnd: Int, lineStartOffset: Int, modelToDisplay: [Int32]?) {
        guard model.hasSemantic, rowEnd > rowStart else { return }
        let absolute = TextSpan(location: lineStartOffset + rowStart, length: rowEnd - rowStart)
        for item in model.decorations.intersecting(absolute) {
            guard case .custom(let code) = item.kind, code >= nativeSemanticBase, code < nativeSemanticBase + 16,
                  let kind = SyntaxKind(rawValue: UInt8(code - nativeSemanticBase)), let color = syntaxColors[kind] else { continue }
            let lower = max(item.range.location - absolute.location, 0)
            let upper = min(item.range.upperBound - absolute.location, rowEnd - rowStart)
            guard upper > lower else { continue }
            let displayLower = modelToDisplay.map { Int($0[lower]) } ?? lower
            let displayUpper = modelToDisplay.map { Int($0[upper]) } ?? upper
            guard displayUpper > displayLower, displayUpper <= text.length else { continue }
            text.addAttribute(.foregroundColor, value: color, range: NSRange(location: displayLower, length: displayUpper - displayLower))
        }
    }

    /// 彩色括号:括号字符按嵌套深度循环取色,未配对的括号用危险色。
    private func applyBrackets(to text: NSMutableAttributedString, rowStart: Int, rowEnd: Int, lineStartOffset: Int, modelToDisplay: [Int32]?) {
        guard rainbowEnabled, rowEnd > rowStart, let store = brackets, store.enabled else { return }
        let absolute = TextSpan(location: lineStartOffset + rowStart, length: rowEnd - rowStart)
        let items = store.brackets.intersecting(absolute)
        guard !items.isEmpty else { return }
        for item in items {
            guard case .custom(let code) = item.kind else { continue }
            let local = item.range.location - absolute.location
            guard local >= 0, local < rowEnd - rowStart else { continue }
            let display = modelToDisplay.map { Int($0[local]) } ?? local
            guard display < text.length else { continue }
            let color = code == BracketCode.unmatched ? unmatchedColor : rainbow[BracketCode.depth(code) % rainbow.count]
            text.addAttribute(.foregroundColor, value: color, range: NSRange(location: display, length: 1))
        }
    }
}
