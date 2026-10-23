// @author ixxxxoooo
// 换行符归一:装载时把 `\r\n` / 孤立 `\r` 统一成 `\n`,并记住原始风格以便保存时还原。

import Foundation

/// 文件的换行风格。
public enum LineEnding: String, Sendable, CaseIterable {
    case lf
    case crlf
    case cr

    /// 该风格对应的换行序列。
    public var sequence: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }

    /// 状态栏显示名。
    public var displayName: String { rawValue.uppercased() }

    /// 归一化结果。
    public struct Normalized: Sendable {
        /// 只含 `\n` 的 UTF-16。
        public var units: ContiguousArray<UInt16>
        /// 占多数的风格(无换行时为 LF)。
        public var dominant: LineEnding
        /// 是否混用了多种风格。
        public var isMixed: Bool
    }

    /// 把任意换行风格的文本归一为 `\n`(单次线性扫描)。
    public static func normalize(_ source: ContiguousArray<UInt16>) -> Normalized {
        var lf = 0, crlf = 0, cr = 0
        var hasCR = false
        source.withUnsafeBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                let unit = buffer[index]
                if unit == 13 {
                    hasCR = true
                    if index + 1 < buffer.count, buffer[index + 1] == 10 { crlf += 1; index += 1 } else { cr += 1 }
                } else if unit == 10 {
                    lf += 1
                }
                index += 1
            }
        }
        let dominant: LineEnding = (crlf >= lf && crlf >= cr && crlf > 0) ? .crlf : (cr > lf && cr > 0 ? .cr : .lf)
        let kinds = (lf > 0 ? 1 : 0) + (crlf > 0 ? 1 : 0) + (cr > 0 ? 1 : 0)
        guard hasCR else { return Normalized(units: source, dominant: dominant, isMixed: false) }
        var output = ContiguousArray<UInt16>()
        output.reserveCapacity(source.count)
        source.withUnsafeBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                let unit = buffer[index]
                if unit == 13 {
                    output.append(10)
                    if index + 1 < buffer.count, buffer[index + 1] == 10 { index += 1 }
                } else {
                    output.append(unit)
                }
                index += 1
            }
        }
        return Normalized(units: output, dominant: dominant, isMixed: kinds > 1)
    }
}
