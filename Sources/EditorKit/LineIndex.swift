// @author ygw
// 行索引:UTF-16 偏移与行号互转,供行号标尺、跳转与 Diff 标记使用。

import Foundation

/// 文本行索引,偏移单位为 UTF-16(与 NSRange 一致)。
public struct LineIndex: Sendable, Equatable {
    /// 每行起始偏移,恒含 0。
    public private(set) var lineStarts: [Int]
    /// 文本总长度(UTF-16)。
    public private(set) var length: Int

    /// 构建索引。
    /// - Parameter text: 文本
    public init(text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        self.lineStarts = starts
        self.length = offset
    }

    /// 行数(末尾换行后的空行也计入)。
    public var lineCount: Int { lineStarts.count }

    /// 查找包含某偏移的行(0 起始)。
    /// - Parameter offset: UTF-16 偏移
    /// - Returns: 行号,越界时夹取到有效范围
    public func line(containing offset: Int) -> Int {
        let clamped = min(max(offset, 0), length)
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= clamped { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// 某行的 UTF-16 范围(含行尾换行符)。
    /// - Parameter line: 行号(0 起始)
    /// - Returns: 范围,越界返回 nil
    public func range(ofLine line: Int) -> NSRange? {
        guard line >= 0, line < lineStarts.count else { return nil }
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return NSRange(location: start, length: end - start)
    }
}
