// @author ixxxxoooo
// Unicode 高亮:找出行内不可见字符、双向控制符、不间断空格,以及夹在拉丁字母单词里的西里尔/希腊形近字。
// 纯函数,按行扫描;纯 ASCII 行走快速路径直接返回。

import Foundation

/// 可疑字符类别。
public enum UnicodeSuspicion: Sendable, Equatable {
    /// 零宽/不可见字符(零宽空格、连接符、软连字符、BOM 等)。
    case invisible
    /// 双向文本控制符(可用于「特洛伊源码」攻击)。
    case bidiControl
    /// 不间断/特殊宽度空格。
    case nonBreakingSpace
    /// 与拉丁字母形近的其它文字字符(混在拉丁单词里)。
    case lookalike
}

/// 一处可疑字符。
public struct UnicodeFinding: Sendable, Equatable {
    /// 行内 UTF-16 偏移。
    public var offset: Int
    /// UTF-16 长度。
    public var length: Int
    /// 类别。
    public var kind: UnicodeSuspicion
}

/// Unicode 扫描器。
public enum UnicodeHighlight {
    /// 与拉丁字母形近的西里尔/希腊字符。
    private static let lookalikes: Set<UInt32> = [
        0x0430, 0x0435, 0x043E, 0x0440, 0x0441, 0x0445, 0x0443, 0x0456, 0x0458, 0x0455, 0x04BB, 0x0501,   // а е о р с х у і ј ѕ һ ԁ
        0x0410, 0x0412, 0x0415, 0x041A, 0x041C, 0x041D, 0x041E, 0x0420, 0x0421, 0x0422, 0x0425,           // А В Е К М Н О Р С Т Х
        0x03BF, 0x03BD, 0x03B9, 0x0391, 0x0392, 0x0395, 0x0396, 0x0397, 0x0399, 0x039A, 0x039C, 0x039D, 0x039F, 0x03A1, 0x03A4, 0x03A7, // 希腊
    ]

    /// 单个标量的类别;普通字符返回 nil。
    public static func classify(_ scalar: UInt32) -> UnicodeSuspicion? {
        switch scalar {
        case 0x200B...0x200D, 0x2060...0x2064, 0x00AD, 0xFEFF, 0x180E, 0x034F, 0x061C: return scalar == 0x061C ? .bidiControl : .invisible
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return .bidiControl
        case 0x00A0, 0x202F, 0x2007, 0x2008, 0x2009, 0x200A, 0x2002...0x2006, 0x205F, 0x3000: return .nonBreakingSpace
        default: return nil
        }
    }

    /// 扫描一行(UTF-16)。
    /// - Parameter units: 行内容
    /// - Returns: 可疑字符(升序)
    public static func scan(_ units: ContiguousArray<UInt16>) -> [UnicodeFinding] {
        guard units.contains(where: { $0 >= 0x80 }) else { return [] }
        var result: [UnicodeFinding] = []
        var index = 0
        // 词内是否含 ASCII 字母(形近字只在混写的词里才可疑)。
        var wordHasLatin = false
        var wordCandidates: [UnicodeFinding] = []
        func flushWord() {
            if wordHasLatin { result.append(contentsOf: wordCandidates) }
            wordHasLatin = false
            wordCandidates.removeAll(keepingCapacity: true)
        }
        while index < units.count {
            var scalar = UInt32(units[index])
            var width = 1
            if (0xD800..<0xDC00).contains(scalar), index + 1 < units.count, (0xDC00..<0xE000).contains(units[index + 1]) {
                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00)
                width = 2
            }
            if let kind = classify(scalar) {
                flushWord()
                result.append(UnicodeFinding(offset: index, length: width, kind: kind))
            } else if scalar < 0x80, (scalar >= 0x41 && scalar <= 0x5A) || (scalar >= 0x61 && scalar <= 0x7A) {
                wordHasLatin = true
            } else if lookalikes.contains(scalar) {
                wordCandidates.append(UnicodeFinding(offset: index, length: width, kind: .lookalike))
            } else if !(scalar < 0x80 && ((scalar >= 0x30 && scalar <= 0x39) || scalar == 0x5F)) {
                // 非字母数字下划线:词结束。
                if let value = Unicode.Scalar(scalar), !value.properties.isAlphabetic { flushWord() }
            }
            index += width
        }
        flushWord()
        return result.sorted { $0.offset < $1.offset }
    }
}
