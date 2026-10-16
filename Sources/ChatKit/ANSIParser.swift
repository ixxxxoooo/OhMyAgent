// @author ixxxxoooo
// ANSI 转义序列解析:把终端输出拆成带样式的片段(前景色、粗体、暗淡、下划线),
// 并处理回车覆盖(进度条)、清行与其他控制序列。纯逻辑,视图层负责映射为颜色。

import Foundation

/// ANSI 颜色。
public enum ANSIColor: Sendable, Equatable {
    /// 标准 16 色(0–7 普通,8–15 高亮)
    case basic(Int)
    /// 256 色调色板
    case palette(Int)
    /// 真彩色
    case rgb(UInt8, UInt8, UInt8)
}

/// 带样式的文本片段。
public struct ANSISpan: Sendable, Equatable {
    public var text: String
    public var foreground: ANSIColor?
    public var bold = false
    public var dim = false
    public var underline = false
}

/// ANSI 解析器。
public enum ANSIParser {
    /// 解析终端输出。
    /// - Parameters:
    ///   - raw: 原始输出
    ///   - maxLines: 只保留末尾的行数(0 表示不限制)
    /// - Returns: 样式片段序列;相邻同样式片段已合并
    public static func parse(_ raw: String, maxLines: Int = 400) -> [ANSISpan] {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if maxLines > 0, lines.count > maxLines { lines = Array(lines.suffix(maxLines)) }

        var spans: [ANSISpan] = []
        var style = ANSISpan(text: "")

        func emit(_ text: String) {
            guard !text.isEmpty else { return }
            if var last = spans.last, last.foreground == style.foreground, last.bold == style.bold,
               last.dim == style.dim, last.underline == style.underline {
                last.text += text
                spans[spans.count - 1] = last
            } else {
                var span = style
                span.text = text
                spans.append(span)
            }
        }

        for (index, line) in lines.enumerated() {
            // 回车覆盖:同一行只保留最后一次 \r 之后的内容(进度条场景)
            let visible = line.contains("\r") ? (line.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? "") : line
            var buffer = ""
            var iterator = visible.unicodeScalars.makeIterator()
            var pending: Unicode.Scalar? = iterator.next()
            while let scalar = pending {
                pending = iterator.next()
                guard scalar == "\u{1B}" else {
                    if scalar.value >= 0x20 || scalar == "\t" { buffer.unicodeScalars.append(scalar) }
                    continue
                }
                guard let next = pending else { break }
                if next == "[" {
                    // CSI:参数字节 0x30–0x3F,中间字节 0x20–0x2F,终止字节 0x40–0x7E
                    pending = iterator.next()
                    var params = ""
                    while let c = pending, c.value >= 0x20 && c.value <= 0x3F {
                        params.unicodeScalars.append(c)
                        pending = iterator.next()
                    }
                    let final = pending
                    pending = iterator.next()
                    if final == "m" {
                        emit(buffer)
                        buffer = ""
                        apply(sgr: params, to: &style)
                    }
                    // 其余 CSI(光标移动、清行等)对静态展示无意义,直接忽略
                } else if next == "]" {
                    // OSC:以 BEL 或 ESC \ 结束
                    pending = iterator.next()
                    while let c = pending {
                        pending = iterator.next()
                        if c == "\u{07}" { break }
                        if c == "\u{1B}" { pending = iterator.next(); break }
                    }
                } else {
                    // 其他两字符序列
                    pending = iterator.next()
                }
            }
            emit(buffer)
            if index < lines.count - 1 { emit("\n") }
        }
        return spans
    }

    /// 去除全部转义序列后的纯文本。
    public static func plainText(_ raw: String, maxLines: Int = 0) -> String {
        parse(raw, maxLines: maxLines).map(\.text).joined()
    }

    // MARK: SGR

    private static func apply(sgr params: String, to style: inout ANSISpan) {
        let codes = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: style = ANSISpan(text: "")
            case 1: style.bold = true
            case 2: style.dim = true
            case 4: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 24: style.underline = false
            case 30...37: style.foreground = .basic(code - 30)
            case 90...97: style.foreground = .basic(code - 90 + 8)
            case 39: style.foreground = nil
            case 38:
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    style.foreground = .palette(codes[index + 2])
                    index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    style.foreground = .rgb(UInt8(clamping: codes[index + 2]), UInt8(clamping: codes[index + 3]), UInt8(clamping: codes[index + 4]))
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }
}
