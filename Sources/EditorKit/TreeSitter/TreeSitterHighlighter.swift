// @author ixxxxoooo
// tree-sitter 高亮器(状态只在所属 actor 内使用):
// - 全文以 UTF-16 小端喂给解析器,字节偏移 / 2 即 UTF-16 偏移,与 `NSRange` 一致;
// - 文本变化时用「公共前后缀」推出单个编辑区间,`ts_tree_edit` 后复用旧树增量重解析;
// - 高亮只对视口范围跑查询(`ts_query_cursor_set_byte_range`),文本谓词在 Swift 里求值。

import CTreeSitter
import Foundation
import OMLog

/// 一次文本编辑(UTF-16 坐标):把 `[location, location + oldLength)` 替换为 `replacement`。
public struct TextUnitEdit: Sendable, Equatable {
    public var location: Int
    public var oldLength: Int
    public var replacement: [UInt16]

    /// - Parameters:
    ///   - location: 起点
    ///   - oldLength: 被替换的长度
    ///   - replacement: 新内容
    public init(location: Int, oldLength: Int, replacement: [UInt16]) {
        self.location = location
        self.oldLength = oldLength
        self.replacement = replacement
    }
}

/// 单个文档的 tree-sitter 状态(非线程安全,只在所属 actor 内使用)。
final class TreeSitterHighlighter {
    private let resources: TreeSitterLanguage
    private let parser: OpaquePointer
    private var tree: OpaquePointer?
    /// 当前树对应的文本(UTF-16)
    private(set) var units: [UInt16] = []
    /// 最近一次解析耗时(毫秒)与是否为增量
    private(set) var lastParseMs: Double = 0
    private(set) var lastWasIncremental = false
    /// 每行起点的 UTF-16 偏移(升序,首项恒为 0);由全量同步建立,编辑时增量维护,用来 O(log n) 求行号
    private var lineStarts: [Int] = [0]

    /// 创建某语言的高亮器。
    /// - Parameter language: 编辑器语言
    /// - Returns: 不支持该语言或解析器创建失败时返回 nil
    init?(language: SyntaxLanguage) {
        guard let resources = TreeSitterLanguage.resolve(language), let parser = ts_parser_new() else { return nil }
        guard ts_parser_set_language(parser, resources.language) else {
            ts_parser_delete(parser)
            return nil
        }
        self.resources = resources
        self.parser = parser
    }

    deinit {
        if let tree { ts_tree_delete(tree) }
        ts_parser_delete(parser)
    }

    /// 同步到新文本:能增量就增量。
    /// - Parameter text: 完整文本
    /// - Returns: 解析是否成功
    @discardableResult
    func update(text: String) -> Bool {
        let new = Array(text.utf16)
        if new == units, tree != nil { return true }
        let started = ContinuousClock.now
        var incremental = false
        if let existing = tree, !units.isEmpty {
            var edit = Self.edit(old: units, new: new)
            ts_tree_edit(existing, &edit)
            incremental = true
        }
        let previous = units
        units = new
        guard reparse(incremental: incremental, started: started) else {
            units = previous
            return false
        }
        lineStarts = Self.lineStarts(of: new)
        return true
    }

    /// 用显式的编辑序列同步(编辑器从文本存储的 `editedRange` 直接得到),不再拷贝整篇文本、整篇比对与前后缀扫描。
    /// 每个编辑的坐标是「前面的编辑都已应用之后」的文档坐标。
    /// - Parameter edits: 编辑序列
    /// - Returns: 是否已增量同步;无树、编辑越界或解析失败时返回 false,调用方应退回 `update(text:)`
    func apply(edits: [TextUnitEdit]) -> Bool {
        guard let existing = tree, !units.isEmpty, !edits.isEmpty else { return false }
        let started = ContinuousClock.now
        for edit in edits {
            let end = edit.location + edit.oldLength
            guard edit.location >= 0, edit.oldLength >= 0, end <= units.count else { return false }
            let startPoint = point(at: edit.location)
            let oldEndPoint = Self.advance(startPoint, from: edit.location, to: end, in: units)
            let newEndPoint = Self.advance(startPoint, over: edit.replacement)
            var input = TSInputEdit(
                start_byte: UInt32(edit.location * 2), old_end_byte: UInt32(end * 2),
                new_end_byte: UInt32((edit.location + edit.replacement.count) * 2),
                start_point: startPoint, old_end_point: oldEndPoint, new_end_point: newEndPoint
            )
            updateLineStarts(edit)
            units.replaceSubrange(edit.location..<end, with: edit.replacement)
            ts_tree_edit(existing, &input)
        }
        guard reparse(incremental: true, started: started) else { return false }
        return true
    }

    /// 以当前 `units` 重新解析(`incremental` 时复用旧树),成功则替换树并记录耗时。
    /// - Returns: 是否解析成功
    private func reparse(incremental: Bool, started: ContinuousClock.Instant) -> Bool {
        let parsed = units.withUnsafeBufferPointer { buffer -> OpaquePointer? in
            guard let base = buffer.baseAddress else {
                // 空文本:给解析器一个有效指针
                var zero: UInt16 = 0
                return withUnsafePointer(to: &zero) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 2) { ts_parser_parse_string_encoding(parser, tree, $0, 0, TSInputEncodingUTF16LE) }
                }
            }
            return base.withMemoryRebound(to: CChar.self, capacity: buffer.count * 2) {
                ts_parser_parse_string_encoding(parser, tree, $0, UInt32(buffer.count * 2), TSInputEncodingUTF16LE)
            }
        }
        guard let parsed else {
            Log.editor.warning("tree-sitter 解析失败,保留旧树")
            return false
        }
        if let old = tree { ts_tree_delete(old) }
        tree = parsed
        let elapsed = ContinuousClock.now - started
        lastParseMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        lastWasIncremental = incremental
        return true
    }

    // MARK: 行起点表

    /// 某 UTF-16 偏移处的点(行从 0 起,列以字节计)。
    private func point(at offset: Int) -> TSPoint {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        let row = max(low - 1, 0)
        return TSPoint(row: UInt32(row), column: UInt32((offset - lineStarts[row]) * 2))
    }

    /// 应用一次编辑后维护行起点表:被替换区间内的行起点移除,新内容里的换行加入,其后的行起点整体平移。
    private func updateLineStarts(_ edit: TextUnitEdit) {
        let oldEnd = edit.location + edit.oldLength
        let delta = edit.replacement.count - edit.oldLength
        // 行起点 s 对应 s-1 处是换行:被替换区间内的换行产生的起点落在 (location, oldEnd]
        var lower = 0
        var high = lineStarts.count
        while lower < high {
            let mid = (lower + high) / 2
            if lineStarts[mid] <= edit.location { lower = mid + 1 } else { high = mid }
        }
        var upper = lower
        while upper < lineStarts.count, lineStarts[upper] <= oldEnd { upper += 1 }
        var inserted: [Int] = []
        for (index, unit) in edit.replacement.enumerated() where unit == 0x0A { inserted.append(edit.location + index + 1) }
        lineStarts.replaceSubrange(lower..<upper, with: inserted)
        if delta != 0 {
            var index = lower + inserted.count
            while index < lineStarts.count { lineStarts[index] += delta; index += 1 }
        }
    }

    /// 整篇文本的行起点表。
    private static func lineStarts(of units: [UInt16]) -> [Int] {
        var starts = [0]
        for (index, unit) in units.enumerated() where unit == 0x0A { starts.append(index + 1) }
        return starts
    }

    /// 从 `origin` 出发扫过一段替换内容后的点。
    private static func advance(_ origin: TSPoint, over replacement: [UInt16]) -> TSPoint {
        var row = origin.row
        var column = Int(origin.column) / 2
        for unit in replacement {
            if unit == 0x0A { row += 1; column = 0 } else { column += 1 }
        }
        return TSPoint(row: row, column: UInt32(column * 2))
    }

    /// 根节点的子节点数(诊断与测试用)。
    var rootChildCount: Int {
        guard let tree else { return 0 }
        return Int(ts_node_child_count(ts_tree_root_node(tree)))
    }

    /// 根节点是否含语法错误。
    var hasErrors: Bool {
        guard let tree else { return false }
        return ts_node_has_error(ts_tree_root_node(tree))
    }

    /// 某范围内的高亮片段,按文档顺序,重叠时后者覆盖前者。
    /// - Parameter range: UTF-16 范围
    func spans(in range: NSRange) -> [SyntaxSpan] {
        guard let tree, range.length > 0, let cursor = ts_query_cursor_new() else { return [] }
        defer { ts_query_cursor_delete(cursor) }
        let start = UInt32(max(range.location, 0) * 2)
        let end = UInt32(min(NSMaxRange(range), units.count) * 2)
        guard start < end else { return [] }
        ts_query_cursor_set_byte_range(cursor, start, end)
        ts_query_cursor_exec(cursor, resources.query, ts_tree_root_node(tree))
        var result: [SyntaxSpan] = []
        var match = TSQueryMatch()
        var index: UInt32 = 0
        while ts_query_cursor_next_capture(cursor, &match, &index) {
            let capture = match.captures[Int(index)]
            if let predicates = resources.predicates[Int(match.pattern_index)], !satisfied(predicates, match: match) {
                ts_query_cursor_remove_match(cursor, match.id)
                continue
            }
            guard Int(capture.index) < resources.captureKinds.count, let kind = resources.captureKinds[Int(capture.index)] else { continue }
            let lower = Int(ts_node_start_byte(capture.node)) / 2
            let upper = Int(ts_node_end_byte(capture.node)) / 2
            guard upper > lower else { continue }
            result.append(SyntaxSpan(location: lower, length: upper - lower, kind: kind))
        }
        return result
    }

    // MARK: 谓词

    /// 某捕获的节点文本。
    private func text(of capture: UInt32, in match: TSQueryMatch) -> String? {
        for offset in 0..<Int(match.capture_count) where match.captures[offset].index == capture {
            let node = match.captures[offset].node
            let lower = Int(ts_node_start_byte(node)) / 2
            let upper = min(Int(ts_node_end_byte(node)) / 2, units.count)
            guard lower <= upper else { return nil }
            return String(decoding: units[lower..<upper], as: UTF16.self)
        }
        return nil
    }

    private func satisfied(_ predicates: [TreeSitterPredicate], match: TSQueryMatch) -> Bool {
        for predicate in predicates {
            switch predicate {
            case .equals(let capture, let other, let literal, let negate):
                guard let value = text(of: capture, in: match) else { continue }
                let target = other.flatMap { text(of: $0, in: match) } ?? literal
                if (value == target) == negate { return false }
            case .matches(let capture, let regex, let negate):
                guard let value = text(of: capture, in: match) else { continue }
                let found = regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
                if found == negate { return false }
            case .anyOf(let capture, let values, let negate):
                guard let value = text(of: capture, in: match) else { continue }
                if values.contains(value) == negate { return false }
            }
        }
        return true
    }

    // MARK: 编辑区间

    /// 由新旧文本的公共前后缀推出 `TSInputEdit`(字节为 UTF-16 偏移 × 2)。
    /// - Parameters:
    ///   - old: 旧文本
    ///   - new: 新文本
    static func edit(old: [UInt16], new: [UInt16]) -> TSInputEdit {
        let limit = min(old.count, new.count)
        var prefix = 0
        while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let oldEnd = old.count - suffix
        let newEnd = new.count - suffix
        // 只整篇扫一次得到起点;终点从起点出发只扫改动片段(原先三次整篇扫描在 5 万行文件上占了大头)
        let start = point(of: prefix, in: old)
        return TSInputEdit(
            start_byte: UInt32(prefix * 2), old_end_byte: UInt32(oldEnd * 2), new_end_byte: UInt32(newEnd * 2),
            start_point: start, old_end_point: advance(start, from: prefix, to: oldEnd, in: old), new_end_point: advance(start, from: prefix, to: newEnd, in: new)
        )
    }

    /// 某 UTF-16 偏移处的行列(列以字节计)。
    /// 从已知位置的点出发,扫描 `[from, to)` 得到 `to` 处的点。
    /// - Parameters:
    ///   - origin: `from` 处的点(列为字节数)
    ///   - from: 起始 UTF-16 偏移
    ///   - to: 目标 UTF-16 偏移(不小于 `from`)
    ///   - units: 文本
    private static func advance(_ origin: TSPoint, from: Int, to: Int, in units: [UInt16]) -> TSPoint {
        var row = origin.row
        var column = Int(origin.column) / 2
        var index = from
        while index < to {
            if units[index] == 0x0A {
                row += 1
                column = 0
            } else {
                column += 1
            }
            index += 1
        }
        return TSPoint(row: row, column: UInt32(column * 2))
    }

    private static func point(of offset: Int, in units: [UInt16]) -> TSPoint {
        var row: UInt32 = 0
        var lineStart = 0
        var index = 0
        while index < offset {
            if units[index] == 0x0A {
                row += 1
                lineStart = index + 1
            }
            index += 1
        }
        return TSPoint(row: row, column: UInt32((offset - lineStart) * 2))
    }
}
