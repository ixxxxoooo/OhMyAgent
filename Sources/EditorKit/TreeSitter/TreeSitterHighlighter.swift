// @author ixxxxoooo
// tree-sitter 高亮器(状态只在所属 actor 内使用):
// - 全文以 UTF-16 小端喂给解析器,字节偏移 / 2 即 UTF-16 偏移,与 `NSRange` 一致;
// - 文本变化时用「公共前后缀」推出单个编辑区间,`ts_tree_edit` 后复用旧树增量重解析;
// - 高亮只对视口范围跑查询(`ts_query_cursor_set_byte_range`),文本谓词在 Swift 里求值。

import CTreeSitter
import Foundation
import OMLog

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
        let parsed = new.withUnsafeBufferPointer { buffer -> OpaquePointer? in
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
        units = new
        let elapsed = ContinuousClock.now - started
        lastParseMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        lastWasIncremental = incremental
        return true
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
        return TSInputEdit(
            start_byte: UInt32(prefix * 2), old_end_byte: UInt32(oldEnd * 2), new_end_byte: UInt32(newEnd * 2),
            start_point: point(of: prefix, in: old), old_end_point: point(of: oldEnd, in: old), new_end_point: point(of: newEnd, in: new)
        )
    }

    /// 某 UTF-16 偏移处的行列(列以字节计)。
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
