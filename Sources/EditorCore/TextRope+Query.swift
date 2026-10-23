// @author ixxxxoooo
// 文本缓冲查询:字符读取、区间切片、行与偏移互转、分块遍历。全部为只读,可在任意线程调用。

import Foundation

extension TextRope {
    // MARK: 单点读取

    /// 读取 `offset` 处的 UTF-16 单元(越界返回 nil)。
    public func unit(at offset: Int) -> UInt16? {
        guard offset >= 0, offset < length else { return nil }
        var node = root
        var remaining = offset
        while !node.isLeaf {
            var next: RopeNode?
            for child in node.children {
                if remaining < child.length { next = child; break }
                remaining -= child.length
            }
            guard let found = next else { return nil }
            node = found
        }
        return node.chunk[remaining]
    }

    // MARK: 区间读取

    /// 按顺序遍历 `range` 覆盖的文本块(零拷贝);`body` 收到的缓冲区只在回调内有效。
    public func forEachChunk(in range: TextSpan, _ body: (UnsafeBufferPointer<UInt16>) -> Void) {
        let lower = min(range.location, length)
        let upper = min(range.upperBound, length)
        guard upper > lower else { return }
        TextRope.visit(root, from: lower, to: upper, body)
    }

    private static func visit(_ node: RopeNode, from lower: Int, to upper: Int, _ body: (UnsafeBufferPointer<UInt16>) -> Void) {
        if node.isLeaf {
            node.chunk.withUnsafeBufferPointer { buffer in
                body(UnsafeBufferPointer(rebasing: buffer[max(lower, 0)..<min(upper, buffer.count)]))
            }
            return
        }
        var start = 0
        for child in node.children {
            let end = start + child.length
            if start >= upper { break }
            if end > lower {
                visit(child, from: lower - start, to: upper - start, body)
            }
            start = end
        }
    }

    /// 取区间文本为 UTF-16 数组(越界夹取)。
    public func slice(_ range: TextSpan) -> ContiguousArray<UInt16> {
        var result = ContiguousArray<UInt16>()
        result.reserveCapacity(min(range.length, length))
        forEachChunk(in: range) { result.append(contentsOf: $0) }
        return result
    }

    /// 取区间文本为字符串(越界夹取)。
    public func string(in range: TextSpan) -> String {
        String(decoding: slice(range), as: UTF16.self)
    }

    /// 全文字符串。
    public func string() -> String { string(in: TextSpan(location: 0, length: length)) }

    // MARK: 行与偏移

    /// 第 `line` 行的起始偏移;`line ≤ 0` 返回 0,超出行数返回文末。
    public func lineStart(_ line: Int) -> Int {
        if line <= 0 { return 0 }
        if line > root.lineBreaks { return length }
        var remaining = line
        var node = root
        var base = 0
        while !node.isLeaf {
            var next: RopeNode?
            for child in node.children {
                if remaining <= child.lineBreaks { next = child; break }
                remaining -= child.lineBreaks
                base += child.length
            }
            guard let found = next else { return length }
            node = found
        }
        var seen = 0
        for (index, unit) in node.chunk.enumerated() where unit == 10 {
            seen += 1
            if seen == remaining { return base + index + 1 }
        }
        return length
    }

    /// 第 `line` 行的内容区间(不含换行符);行号越界返回 nil。
    public func lineRange(_ line: Int) -> TextSpan? {
        guard line >= 0, line < lineCount else { return nil }
        let start = lineStart(line)
        let end = line + 1 < lineCount ? lineStart(line + 1) - 1 : length
        return TextSpan(lower: start, upper: end)
    }

    /// 偏移所在行号(0 起);偏移超界夹取到文末。
    public func line(containing offset: Int) -> Int {
        var remaining = min(max(offset, 0), length)
        var count = 0
        var node = root
        while !node.isLeaf {
            var next: RopeNode?
            for child in node.children {
                if remaining <= child.length { next = child; break }
                remaining -= child.length
                count += child.lineBreaks
            }
            guard let found = next else { return count }
            node = found
        }
        for index in 0..<min(remaining, node.chunk.count) where node.chunk[index] == 10 { count += 1 }
        return count
    }

    /// 偏移转行列位置。
    public func position(at offset: Int) -> TextPosition {
        let clamped = min(max(offset, 0), length)
        let line = line(containing: clamped)
        return TextPosition(line: line, column: clamped - lineStart(line))
    }

    /// 行列位置转偏移;行越界夹取到末行,列超出行长夹取到行尾。
    public func offset(of position: TextPosition) -> Int {
        let line = min(max(position.line, 0), lineCount - 1)
        guard let range = lineRange(line) else { return length }
        return range.location + min(max(position.column, 0), range.length)
    }

    /// 某行的内容字符串(不含换行符)。
    public func lineText(_ line: Int) -> String {
        guard let range = lineRange(line) else { return "" }
        return string(in: range)
    }

    /// 某行的 UTF-16 内容长度(不含换行符)。
    public func lineLength(_ line: Int) -> Int { lineRange(line)?.length ?? 0 }
}
