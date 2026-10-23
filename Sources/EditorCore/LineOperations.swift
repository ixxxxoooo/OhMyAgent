// @author ixxxxoooo
// 行级编辑命令(纯函数):移动/复制/删除行、合并行、上下插入新行、行注释与块注释切换、排序、大小写转换、去行尾空白。
// 每个命令只产出「编辑列表 + 编辑后选区」,由视图模型一次性提交为单个撤销步骤。

import Foundation

/// 一次命令的产出。
public struct EditOutcome: Sendable, Equatable {
    /// 以原文档坐标表示、按位置升序且互不重叠的编辑。
    public var edits: [DocumentEdit]
    /// 编辑后的选区(与命令输入的选区一一对应,可含重合项,由 `SelectionSet` 合并)。
    public var selections: [Selection]

    public init(edits: [DocumentEdit], selections: [Selection]) {
        self.edits = edits
        self.selections = selections
    }
}

/// 行级编辑命令集合。
public enum LineOperations {
    // MARK: 公共工具

    /// 选区覆盖的行区间(选区末端恰在下一行行首且非空时不含该行)。
    public static func coveredLines(of selection: Selection, in rope: TextRope) -> ClosedRange<Int> {
        let range = selection.range
        let first = rope.line(containing: range.location)
        var last = rope.line(containing: range.upperBound)
        if last > first, !range.isEmpty, range.upperBound == rope.lineStart(last) { last -= 1 }
        return first...last
    }

    /// 全部选区覆盖的行区间,相邻或重叠的合并,升序。
    public static func lineBlocks(of selections: [Selection], in rope: TextRope) -> [ClosedRange<Int>] {
        let sorted = selections.map { coveredLines(of: $0, in: rope) }.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Int>] = []
        for block in sorted {
            if let last = result.last, block.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, block.upperBound)
            } else {
                result.append(block)
            }
        }
        return result
    }

    /// 某行内容末尾的偏移(不含换行符)。
    static func lineEnd(_ line: Int, in rope: TextRope) -> Int { rope.lineStart(line) + rope.lineLength(line) }

    /// 把偏移经一组升序编辑映射到新坐标;落在被替换区间内的偏移取决于 `preferRight`。
    public static func map(_ offset: Int, through edits: [DocumentEdit], preferRight: Bool) -> Int {
        var delta = 0
        for edit in edits {
            let range = edit.range
            let newLength = edit.text.utf16.count
            if offset < range.location || (offset == range.location && !preferRight && range.isEmpty) { break }
            if offset >= range.upperBound && !(offset == range.upperBound && range.isEmpty && !preferRight) {
                delta += newLength - range.length
                continue
            }
            // 落在被替换区间内部(或空插入点且偏向右)。
            return range.location + delta + (preferRight ? newLength : 0)
        }
        return offset + delta
    }

    /// 以「偏移映射」方式生成编辑后选区:空选区偏右,非空选区起点偏左、终点偏右。
    public static func mapSelections(_ selections: [Selection], through edits: [DocumentEdit]) -> [Selection] {
        selections.map { selection in
            if selection.isEmpty {
                let caret = map(selection.head, through: edits, preferRight: true)
                return Selection(caret: caret)
            }
            let range = selection.range
            let start = map(range.location, through: edits, preferRight: false)
            let end = map(range.upperBound, through: edits, preferRight: true)
            return selection.isReversed ? Selection(anchor: end, head: start) : Selection(anchor: start, head: end)
        }
    }

    // MARK: 移动行

    /// 上移/下移选区覆盖的行。
    /// - Returns: 无可移动的行(已在边界)时返回 nil
    public static func moveLines(rope: TextRope, selections: [Selection], up: Bool) -> EditOutcome? {
        let blocks = lineBlocks(of: selections, in: rope)
        var edits: [DocumentEdit] = []
        /// (块起点偏移, 块终点偏移, 位移量)
        var shifts: [(Int, Int, Int)] = []
        var lastUsed = -1
        for block in blocks {
            let a = block.lowerBound, b = block.upperBound
            if up {
                guard a > 0, a - 1 > lastUsed else { continue }
                let previous = rope.lineText(a - 1)
                let body = (a...b).map { rope.lineText($0) }
                let range = TextSpan(lower: rope.lineStart(a - 1), upper: lineEnd(b, in: rope))
                edits.append(DocumentEdit(range: range, text: (body + [previous]).joined(separator: "\n")))
                shifts.append((rope.lineStart(a), lineEnd(b, in: rope), -(previous.utf16.count + 1)))
                lastUsed = b
            } else {
                guard b + 1 < rope.lineCount, a > lastUsed else { continue }
                let next = rope.lineText(b + 1)
                let body = (a...b).map { rope.lineText($0) }
                let range = TextSpan(lower: rope.lineStart(a), upper: lineEnd(b + 1, in: rope))
                edits.append(DocumentEdit(range: range, text: ([next] + body).joined(separator: "\n")))
                shifts.append((rope.lineStart(a), lineEnd(b, in: rope), next.utf16.count + 1))
                lastUsed = b + 1
            }
        }
        guard !edits.isEmpty else { return nil }
        func shift(_ offset: Int) -> Int {
            for (start, end, delta) in shifts where offset >= start && offset <= end { return offset + delta }
            return offset
        }
        let after = selections.map { Selection(anchor: shift($0.anchor), head: shift($0.head)) }
        return EditOutcome(edits: edits, selections: after)
    }

    // MARK: 复制行

    /// 向上/向下复制选区覆盖的行。向下复制后选区落在新副本上,向上复制保持在上方副本。
    public static func duplicateLines(rope: TextRope, selections: [Selection], down: Bool) -> EditOutcome {
        let blocks = lineBlocks(of: selections, in: rope)
        var edits: [DocumentEdit] = []
        struct Info { var start: Int; var end: Int; var before: Int; var inserted: Int }
        var infos: [Info] = []
        var cumulative = 0
        for block in blocks {
            let a = block.lowerBound, b = block.upperBound
            let body = (a...b).map { rope.lineText($0) }.joined(separator: "\n")
            let inserted = body.utf16.count + 1
            if down {
                edits.append(DocumentEdit(range: TextSpan(location: lineEnd(b, in: rope), length: 0), text: "\n" + body))
            } else {
                edits.append(DocumentEdit(range: TextSpan(location: rope.lineStart(a), length: 0), text: body + "\n"))
            }
            infos.append(Info(start: rope.lineStart(a), end: lineEnd(b, in: rope), before: cumulative, inserted: inserted))
            cumulative += inserted
        }
        func shift(_ offset: Int) -> Int {
            var total = 0
            for info in infos {
                if offset >= info.start && offset <= info.end {
                    return offset + info.before + (down ? info.inserted : 0)
                }
                if offset > info.end { total = info.before + info.inserted }
            }
            return offset + total
        }
        return EditOutcome(edits: edits, selections: selections.map { Selection(anchor: shift($0.anchor), head: shift($0.head)) })
    }

    // MARK: 删除行

    /// 删除选区覆盖的整行,光标落在后续行首(末行被删则落在新末行行首)。
    public static func deleteLines(rope: TextRope, selections: [Selection]) -> EditOutcome {
        let blocks = lineBlocks(of: selections, in: rope)
        var edits: [DocumentEdit] = []
        var carets: [(block: ClosedRange<Int>, caret: Int)] = []
        var removed = 0
        for block in blocks {
            let a = block.lowerBound, b = block.upperBound
            let range: TextSpan
            let target: Int
            if b + 1 < rope.lineCount {
                range = TextSpan(lower: rope.lineStart(a), upper: rope.lineStart(b + 1))
                target = rope.lineStart(a)
            } else if a > 0 {
                range = TextSpan(lower: rope.lineStart(a) - 1, upper: rope.length)
                target = rope.lineStart(a - 1)
            } else {
                range = TextSpan(lower: 0, upper: rope.length)
                target = 0
            }
            edits.append(DocumentEdit(range: range, text: ""))
            carets.append((block, target - removed))
            removed += range.length
        }
        let after = selections.map { selection -> Selection in
            let line = rope.line(containing: selection.head)
            let found = carets.first { $0.block.contains(line) }
            return Selection(caret: found?.caret ?? 0)
        }
        return EditOutcome(edits: edits, selections: after)
    }

    // MARK: 合并行

    /// 合并行:每个选区把覆盖的行(单行则与下一行)连成一行,下一行的前导空白折叠为一个空格。
    public static func joinLines(rope: TextRope, selections: [Selection]) -> EditOutcome? {
        var joinedLines = Set<Int>()
        var points: [(first: Int, last: Int)] = []
        for selection in selections {
            let covered = coveredLines(of: selection, in: rope)
            var last = covered.upperBound
            if covered.lowerBound == last { last += 1 }
            guard last < rope.lineCount else { continue }
            points.append((covered.lowerBound, last))
            for line in covered.lowerBound..<last { joinedLines.insert(line) }
        }
        guard !joinedLines.isEmpty else { return nil }
        var edits: [DocumentEdit] = []
        var caretOfLine: [Int: Int] = [:]
        var removed = 0
        for line in joinedLines.sorted() {
            let end = lineEnd(line, in: rope)
            let next = line + 1
            let lead = CursorMotion.leadingWhitespaceLength(ofLine: next, in: rope)
            let nextContentStart = rope.lineStart(next) + lead
            let currentText = rope.lineText(line)
            let nextText = rope.lineText(next)
            let nextBody = (nextText as NSString).substring(from: lead)
            let needsSpace = !currentText.isEmpty && !(currentText.last == " " || currentText.last == "\t")
                && !nextBody.isEmpty && nextBody.first != ")"
            let range = TextSpan(lower: end, upper: nextContentStart)
            edits.append(DocumentEdit(range: range, text: needsSpace ? " " : ""))
            caretOfLine[line] = end - removed
            removed += range.length - (needsSpace ? 1 : 0)
        }
        let mapped = mapSelections(selections, through: edits)
        let after = zip(selections, mapped).map { selection, mappedSelection -> Selection in
            guard selection.isEmpty else { return mappedSelection }
            let line = rope.line(containing: selection.head)
            return Selection(caret: caretOfLine[line] ?? mappedSelection.head)
        }
        return EditOutcome(edits: edits, selections: after)
    }

    // MARK: 插入新行

    /// 在当前行下方/上方插入新行并沿用缩进(下方时行尾为 `{([:` 额外缩进一级)。
    public static func insertLine(rope: TextRope, selections: [Selection], below: Bool, indentUnit: String) -> EditOutcome {
        let lines = Array(Set(selections.map { rope.line(containing: $0.head) })).sorted()
        var edits: [DocumentEdit] = []
        var caretOfLine: [Int: Int] = [:]
        var cumulative = 0
        for line in lines {
            let lead = CursorMotion.leadingWhitespaceLength(ofLine: line, in: rope)
            let indent = rope.string(in: TextSpan(location: rope.lineStart(line), length: lead))
            if below {
                let text = rope.lineText(line)
                let extra = "{([:".contains(text.last ?? " ") ? indentUnit : ""
                let insert = "\n" + indent + extra
                let location = lineEnd(line, in: rope)
                edits.append(DocumentEdit(range: TextSpan(location: location, length: 0), text: insert))
                caretOfLine[line] = location + cumulative + insert.utf16.count
                cumulative += insert.utf16.count
            } else {
                let location = rope.lineStart(line)
                let insert = indent + "\n"
                edits.append(DocumentEdit(range: TextSpan(location: location, length: 0), text: insert))
                caretOfLine[line] = location + cumulative + indent.utf16.count
                cumulative += insert.utf16.count
            }
        }
        let after = selections.map { Selection(caret: caretOfLine[rope.line(containing: $0.head)] ?? $0.head) }
        return EditOutcome(edits: edits, selections: after)
    }

    // MARK: 注释

    /// 切换行注释:覆盖的非空行都已注释则取消,否则在最小缩进列处统一加注释。
    public static func toggleLineComment(rope: TextRope, selections: [Selection], prefix: String) -> EditOutcome? {
        guard !prefix.isEmpty else { return nil }
        var edits: [DocumentEdit] = []
        for block in lineBlocks(of: selections, in: rope) {
            struct LineInfo { var line: Int; var indent: Int; var text: String }
            var infos: [LineInfo] = []
            for line in block {
                let text = rope.lineText(line)
                let indent = text.prefix { $0 == " " || $0 == "\t" }.utf16.count
                if text.utf16.count > indent { infos.append(LineInfo(line: line, indent: indent, text: text)) }
            }
            guard !infos.isEmpty else { continue }
            let allCommented = infos.allSatisfy { info in
                (info.text as NSString).substring(from: info.indent).hasPrefix(prefix)
            }
            if allCommented {
                for info in infos {
                    let start = rope.lineStart(info.line) + info.indent
                    var length = prefix.utf16.count
                    let rest = (info.text as NSString).substring(from: info.indent + length)
                    if rest.hasPrefix(" ") { length += 1 }
                    edits.append(DocumentEdit(range: TextSpan(location: start, length: length), text: ""))
                }
            } else {
                let column = infos.map(\.indent).min() ?? 0
                for info in infos {
                    edits.append(DocumentEdit(range: TextSpan(location: rope.lineStart(info.line) + column, length: 0), text: prefix + " "))
                }
            }
        }
        guard !edits.isEmpty else { return nil }
        return EditOutcome(edits: edits, selections: mapSelections(selections, through: edits))
    }

    /// 切换块注释:选区(空选区取所在行去空白内容)被 `open`/`close` 包裹则取消,否则包裹。
    public static func toggleBlockComment(rope: TextRope, selections: [Selection], open: String, close: String) -> EditOutcome? {
        guard !open.isEmpty, !close.isEmpty else { return nil }
        var edits: [DocumentEdit] = []
        var seen = Set<Int>()
        for selection in selections {
            var range = selection.range
            if range.isEmpty {
                let line = rope.line(containing: range.location)
                let text = rope.lineText(line)
                let lead = text.prefix { $0 == " " || $0 == "\t" }.utf16.count
                let trailing = text.reversed().prefix { $0 == " " || $0 == "\t" }.count
                let length = text.utf16.count - lead - trailing
                guard length > 0 else { continue }
                range = TextSpan(location: rope.lineStart(line) + lead, length: length)
            }
            guard seen.insert(range.location).inserted else { continue }
            let text = rope.string(in: range)
            if text.hasPrefix(open), text.hasSuffix(close), text.utf16.count >= open.utf16.count + close.utf16.count {
                var inner = String(text.dropFirst(open.count).dropLast(close.count))
                if inner.hasPrefix(" ") { inner.removeFirst() }
                if inner.hasSuffix(" ") { inner.removeLast() }
                edits.append(DocumentEdit(range: range, text: inner))
            } else {
                edits.append(DocumentEdit(range: range, text: open + " " + text + " " + close))
            }
        }
        guard !edits.isEmpty else { return nil }
        return EditOutcome(edits: edits, selections: mapSelections(selections, through: edits))
    }

    // MARK: 排序、大小写、空白

    /// 对选区覆盖的行排序(单个光标时排序全文)。
    public static func sortLines(rope: TextRope, selections: [Selection], descending: Bool) -> EditOutcome? {
        let blocks: [ClosedRange<Int>]
        if selections.count == 1, selections[0].isEmpty { blocks = [0...(rope.lineCount - 1)] }
        else { blocks = lineBlocks(of: selections, in: rope) }
        var edits: [DocumentEdit] = []
        for block in blocks where block.count > 1 {
            let lines = block.map { rope.lineText($0) }
            let sorted = lines.sorted { descending ? $0.localizedStandardCompare($1) == .orderedDescending : $0.localizedStandardCompare($1) == .orderedAscending }
            guard sorted != lines else { continue }
            edits.append(DocumentEdit(range: TextSpan(lower: rope.lineStart(block.lowerBound), upper: lineEnd(block.upperBound, in: rope)),
                                      text: sorted.joined(separator: "\n")))
        }
        guard !edits.isEmpty else { return nil }
        return EditOutcome(edits: edits, selections: selections)
    }

    /// 大小写转换种类。
    public enum CaseTransform: Sendable { case upper, lower, title }

    /// 转换选区文本大小写(空光标取所在单词)。
    public static func transformCase(rope: TextRope, selections: [Selection], transform: CaseTransform) -> EditOutcome? {
        var edits: [DocumentEdit] = []
        var after = selections
        for (index, selection) in selections.enumerated() {
            var range = selection.range
            if range.isEmpty { range = CursorMotion.wordRange(at: range.location, in: rope) }
            guard range.length > 0 else { continue }
            let text = rope.string(in: range)
            let converted: String
            switch transform {
            case .upper: converted = text.uppercased()
            case .lower: converted = text.lowercased()
            case .title: converted = text.capitalized
            }
            guard converted != text else { continue }
            edits.append(DocumentEdit(range: range, text: converted))
            if !selection.isEmpty { after[index] = selection }
        }
        guard !edits.isEmpty else { return nil }
        // 长度可能变化(如 ß→SS),选区按编辑映射。
        return EditOutcome(edits: edits, selections: mapSelections(after, through: edits))
    }

    /// 去除全文行尾空白。
    public static func trimTrailingWhitespace(rope: TextRope, selections: [Selection]) -> EditOutcome? {
        var edits: [DocumentEdit] = []
        for line in 0..<rope.lineCount {
            guard let range = rope.lineRange(line), range.length > 0 else { continue }
            var trailing = 0
            var position = range.upperBound - 1
            while position >= range.location, let unit = rope.unit(at: position), unit == 0x20 || unit == 0x09 {
                trailing += 1
                position -= 1
            }
            if trailing > 0 { edits.append(DocumentEdit(range: TextSpan(location: range.upperBound - trailing, length: trailing), text: "")) }
        }
        guard !edits.isEmpty else { return nil }
        return EditOutcome(edits: edits, selections: mapSelections(selections, through: edits))
    }
}
