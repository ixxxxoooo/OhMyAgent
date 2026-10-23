// @author ixxxxoooo
// 光标移动的纯函数:字符边界(代理对、组合符、ZWJ 表情序列)、单词边界、行首行尾(智能 Home)、缩进。
// 全部只读 `TextRope`,偏移单位 UTF-16;可在任意线程调用。

import Foundation

/// 字符类别(单词移动与双击选词用)。
public enum CharacterClass: Sendable, Equatable {
    case newline, space, word, punctuation, cjk
}

public enum CursorMotion {
    // MARK: 字符类别

    /// 判定标量所属类别。
    public static func classify(_ scalar: UInt32) -> CharacterClass {
        if scalar == 10 { return .newline }
        if scalar == 0x20 || scalar == 9 || scalar == 0xA0 || scalar == 0x3000 { return .space }
        if scalar == 0x5F { return .word }
        if (scalar >= 0x30 && scalar <= 0x39) || (scalar >= 0x41 && scalar <= 0x5A) || (scalar >= 0x61 && scalar <= 0x7A) { return .word }
        if scalar < 0x80 { return .punctuation }
        if (scalar >= 0x3040 && scalar <= 0x30FF) || (scalar >= 0x3400 && scalar <= 0x9FFF) || (scalar >= 0xAC00 && scalar <= 0xD7A3) { return .cjk }
        if let value = Unicode.Scalar(scalar) {
            if value.properties.isAlphabetic || value.properties.numericType != nil { return .word }
            if value.properties.isWhitespace { return .space }
        }
        return .punctuation
    }

    /// 是否为「附着」标量:组合符、变体选择符、肤色修饰、零宽连接符(附着在前一个字符上,不单独成光标位置)。
    static func isExtender(_ scalar: UInt32) -> Bool {
        (scalar >= 0x300 && scalar <= 0x36F) || (scalar >= 0x1AB0 && scalar <= 0x1AFF) || (scalar >= 0x1DC0 && scalar <= 0x1DFF)
            || (scalar >= 0x20D0 && scalar <= 0x20FF) || (scalar >= 0xFE00 && scalar <= 0xFE0F) || (scalar >= 0xFE20 && scalar <= 0xFE2F)
            || (scalar >= 0x1F3FB && scalar <= 0x1F3FF) || scalar == 0x200D || (scalar >= 0xE0020 && scalar <= 0xE007F)
    }

    // MARK: 标量读取

    /// 读取 `offset` 处的标量与其 UTF-16 宽度。
    static func scalar(in rope: TextRope, at offset: Int) -> (value: UInt32, width: Int)? {
        guard let unit = rope.unit(at: offset) else { return nil }
        if unit >= 0xD800 && unit < 0xDC00, let low = rope.unit(at: offset + 1), low >= 0xDC00 && low < 0xE000 {
            return (0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00), 2)
        }
        return (UInt32(unit), 1)
    }

    /// 读取 `offset` 之前的标量与宽度。
    static func scalar(before offset: Int, in rope: TextRope) -> (value: UInt32, width: Int)? {
        guard offset > 0, let unit = rope.unit(at: offset - 1) else { return nil }
        if unit >= 0xDC00 && unit < 0xE000, offset >= 2, let high = rope.unit(at: offset - 2), high >= 0xD800 && high < 0xDC00 {
            return (0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00), 2)
        }
        return (UInt32(unit), 1)
    }

    // MARK: 字符边界

    /// 下一个字符边界(跨过整个字素簇:代理对、组合符、ZWJ 序列、区域旗帜);文末返回文末。
    public static func nextCharacter(_ offset: Int, in rope: TextRope) -> Int {
        guard var current = scalar(in: rope, at: offset) else { return rope.length }
        var position = offset + current.width
        let isRegional = current.value >= 0x1F1E6 && current.value <= 0x1F1FF
        if isRegional, let next = scalar(in: rope, at: position), next.value >= 0x1F1E6 && next.value <= 0x1F1FF {
            position += next.width
        }
        while let next = scalar(in: rope, at: position), isExtender(next.value) {
            position += next.width
            if next.value == 0x200D, let joined = scalar(in: rope, at: position) {
                position += joined.width
                current = joined
            }
        }
        return position
    }

    /// 上一个字符边界;文首返回 0。
    public static func previousCharacter(_ offset: Int, in rope: TextRope) -> Int {
        guard var current = scalar(before: min(offset, rope.length), in: rope) else { return 0 }
        var position = min(offset, rope.length) - current.width
        while position > 0 {
            if isExtender(current.value) || (current.value == 0x200D) {
                guard let previous = scalar(before: position, in: rope) else { break }
                position -= previous.width
                current = previous
                continue
            }
            // 前一个标量是 ZWJ:当前标量与它们连成一个簇。
            if let previous = scalar(before: position, in: rope), previous.value == 0x200D {
                position -= previous.width
                guard let base = scalar(before: position, in: rope) else { break }
                position -= base.width
                current = base
                continue
            }
            // 区域旗帜成对。
            if current.value >= 0x1F1E6 && current.value <= 0x1F1FF,
               let previous = scalar(before: position, in: rope), previous.value >= 0x1F1E6 && previous.value <= 0x1F1FF {
                var count = 0
                var probe = position
                while let item = scalar(before: probe, in: rope), item.value >= 0x1F1E6 && item.value <= 0x1F1FF {
                    count += 1
                    probe -= item.width
                }
                if count % 2 == 1 { position -= previous.width }
            }
            break
        }
        return position
    }

    // MARK: 单词

    /// 向右到下一个词尾:先跳过空白,再跳过同类字符;行尾时越过换行到下一行。
    public static func nextWordEnd(_ offset: Int, in rope: TextRope) -> Int {
        var position = min(offset, rope.length)
        guard position < rope.length else { return rope.length }
        if let first = scalar(in: rope, at: position), classify(first.value) == .newline { return position + 1 }
        while let item = scalar(in: rope, at: position), classify(item.value) == .space { position += item.width }
        guard let head = scalar(in: rope, at: position) else { return position }
        let kind = classify(head.value)
        if kind == .newline { return position }
        while let item = scalar(in: rope, at: position), classify(item.value) == kind { position += item.width }
        return position
    }

    /// 向左到上一个词首。
    public static func previousWordStart(_ offset: Int, in rope: TextRope) -> Int {
        var position = min(offset, rope.length)
        guard position > 0 else { return 0 }
        if let item = scalar(before: position, in: rope), classify(item.value) == .newline { return position - 1 }
        while let item = scalar(before: position, in: rope), classify(item.value) == .space { position -= item.width }
        guard let head = scalar(before: position, in: rope) else { return position }
        let kind = classify(head.value)
        if kind == .newline { return position }
        while let item = scalar(before: position, in: rope), classify(item.value) == kind { position -= item.width }
        return position
    }

    /// 包含 `offset` 的「单词」区间(双击选词):同类字符连续段;空白段也成区间。
    public static func wordRange(at offset: Int, in rope: TextRope) -> TextSpan {
        let position = min(offset, rope.length)
        let lineRange = rope.lineRange(rope.line(containing: position)) ?? TextSpan(location: position, length: 0)
        if lineRange.isEmpty { return TextSpan(location: position, length: 0) }
        // 光标在行尾时取前一个字符所属的词。
        let probe = (position >= lineRange.upperBound) ? max(lineRange.location, position - 1) : position
        guard let head = scalar(in: rope, at: probe) else { return TextSpan(location: position, length: 0) }
        let kind = classify(head.value)
        var start = probe
        while start > lineRange.location, let item = scalar(before: start, in: rope), classify(item.value) == kind { start -= item.width }
        var end = probe
        while end < lineRange.upperBound, let item = scalar(in: rope, at: end), classify(item.value) == kind { end += item.width }
        return TextSpan(lower: start, upper: end)
    }

    // MARK: 行首行尾与缩进

    /// 行首的空白(空格/制表符)长度。
    public static func leadingWhitespaceLength(ofLine line: Int, in rope: TextRope) -> Int {
        guard let range = rope.lineRange(line) else { return 0 }
        var count = 0
        while count < range.length, let unit = rope.unit(at: range.location + count), unit == 0x20 || unit == 9 { count += 1 }
        return count
    }

    /// 智能 Home:光标不在首个非空白处则移到那里,否则移到行首。
    public static func smartLineStart(from offset: Int, in rope: TextRope) -> Int {
        let line = rope.line(containing: offset)
        guard let range = rope.lineRange(line) else { return 0 }
        let firstText = range.location + leadingWhitespaceLength(ofLine: line, in: rope)
        return offset == firstText ? range.location : firstText
    }

    /// 行尾(不含换行符)。
    public static func lineEnd(from offset: Int, in rope: TextRope) -> Int {
        rope.lineRange(rope.line(containing: offset))?.upperBound ?? rope.length
    }

    /// 行首(不含智能处理)。
    public static func lineStart(from offset: Int, in rope: TextRope) -> Int {
        rope.lineStart(rope.line(containing: offset))
    }
}
