// @author ixxxxoooo
// 行索引:UTF-16 偏移与行号互转,供行号标尺、跳转与 Diff 标记使用;
// 同时记录每行的「显示列数」,用来在不换行模式下估算内容宽度(避免让 TextKit 为量宽做全量布局)。
// 支持增量更新(`applyEdit`):单次按键只改动受影响的几行,不再随文件大小线性重建。

import Foundation

/// 文本行索引,偏移单位为 UTF-16(与 NSRange 一致)。
public struct LineIndex: Sendable, Equatable {
    /// 每行起始偏移,恒含 0。
    public private(set) var lineStarts: [Int]
    /// 文本总长度(UTF-16)。
    public private(set) var length: Int
    /// 每行的显示列数(与 `lineStarts` 一一对应,不含换行符):制表符按 `tabColumns` 计,
    /// 码点 ≥ U+2E80(中日韩、全角、表情等)按 2 列计,其余 1 列。是估算宽度用的保守值,不是精确排版。
    public private(set) var lineColumns: [Int32]
    /// 制表符折算的列数。
    public let tabColumns: Int

    /// 构建索引。
    /// - Parameters:
    ///   - text: 文本
    ///   - tabColumns: 制表符折算列数(夹取到 1…16)
    public init(text: String, tabColumns: Int = 4) {
        let tabs = min(max(tabColumns, 1), 16)
        self.tabColumns = tabs
        var scanner = ColumnScanner(tabColumns: tabs)
        var text = text
        text.withUTF8 { scanner.scan($0) }
        self.lineStarts = scanner.starts
        self.lineColumns = scanner.columns + [Int32(scanner.currentColumns)]
        self.length = scanner.offset
    }

    /// 行数(末尾换行后的空行也计入)。
    public var lineCount: Int { lineStarts.count }

    /// 全文最宽一行的列数(不换行模式估算内容宽度用)。O(行数)。
    public var longestColumns: Int { Int(lineColumns.max() ?? 0) }

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

    // MARK: 增量更新

    /// 应用一次文本编辑,只重算受影响的行(代价 ∝ 受影响行数 + 行数的一次数组平移,与文件字符数无关)。
    /// - Parameters:
    ///   - editedRange: 编辑后新文本占据的范围(UTF-16;纯删除时长度为 0)
    ///   - changeInLength: 长度变化(新长度 − 旧长度)
    ///   - text: 编辑后的完整文本(只读取受影响行的字符)
    /// - Returns: 参数自洽并已应用返回 true;范围越界等不一致返回 false(调用方应整体重建)
    @discardableResult
    public mutating func applyEdit(editedRange: NSRange, changeInLength: Int, text: NSString) -> Bool {
        let oldLength = editedRange.length - changeInLength
        let newTotal = length + changeInLength
        guard editedRange.location >= 0, editedRange.length >= 0, oldLength >= 0,
              editedRange.location + oldLength <= length, newTotal == text.length,
              NSMaxRange(editedRange) <= text.length else { return false }
        let oldStart = editedRange.location
        let oldEnd = oldStart + oldLength

        let firstLine = line(containing: oldStart)
        let lastLine = line(containing: oldEnd)

        // 新文本里的换行产生新的行起点
        var newStarts: [Int] = []
        if editedRange.length > 0 {
            var buffer = [unichar](repeating: 0, count: min(editedRange.length, 4_096))
            var position = editedRange.location
            let end = NSMaxRange(editedRange)
            while position < end {
                let count = min(buffer.count, end - position)
                buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: position, length: count)) }
                for index in 0..<count where buffer[index] == 0x0A { newStarts.append(position + index + 1) }
                position += count
            }
        }

        // 拼接:保留 [0…firstLine],接上新起点,再接 lastLine 之后整体平移的旧起点
        let tail = lineStarts[(lastLine + 1)...].map { $0 + changeInLength }
        lineStarts.removeSubrange((firstLine + 1)...)
        lineStarts.append(contentsOf: newStarts)
        lineStarts.append(contentsOf: tail)
        length = newTotal

        // 重算受影响行的列数:firstLine …(firstLine + 新增起点数)
        let affectedCount = newStarts.count + 1
        var recomputed: [Int32] = []
        recomputed.reserveCapacity(affectedCount)
        for line in firstLine..<(firstLine + affectedCount) {
            let start = lineStarts[line]
            var end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
            if line + 1 < lineStarts.count { end -= 1 }   // 去掉行尾换行符
            recomputed.append(Int32(Self.columns(in: text, range: NSRange(location: start, length: max(end - start, 0)), tabColumns: tabColumns)))
        }
        lineColumns.replaceSubrange(firstLine...lastLine, with: recomputed)
        return true
    }

    // MARK: 列数计算

    /// 计算 UTF-16 范围内的显示列数(规则同 `lineColumns`)。
    static func columns(in text: NSString, range: NSRange, tabColumns: Int) -> Int {
        guard range.length > 0 else { return 0 }
        var buffer = [unichar](repeating: 0, count: min(range.length, 4_096))
        var total = 0
        var position = range.location
        let end = NSMaxRange(range)
        while position < end {
            let count = min(buffer.count, end - position)
            buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: position, length: count)) }
            for index in 0..<count {
                let unit = buffer[index]
                if unit == 0x09 { total += tabColumns }
                else if unit >= 0xDC00 && unit <= 0xDFFF { continue }   // 低代理项:与高代理项合计 2 列
                else if unit >= 0x2E80 { total += 2 }
                else { total += 1 }
            }
            position += count
        }
        return total
    }

    /// 按 UTF-8 字节单遍扫描(原生 Swift 字符串可连续访问,比逐个 UTF-16 单元快),同时统计偏移、行起点与每行列数。
    private struct ColumnScanner {
        let tabColumns: Int
        var starts: [Int] = [0]
        var columns: [Int32] = []
        var offset = 0
        var currentColumns = 0

        init(tabColumns: Int) { self.tabColumns = tabColumns }

        mutating func scan(_ bytes: UnsafeBufferPointer<UInt8>) {
            var index = 0
            let count = bytes.count
            while index < count {
                let byte = bytes[index]
                switch byte {
                case 0x0A:
                    offset += 1
                    columns.append(Int32(currentColumns))
                    currentColumns = 0
                    starts.append(offset)
                    index += 1
                case 0x09:
                    offset += 1; currentColumns += tabColumns; index += 1
                case 0x00...0x7F:
                    offset += 1; currentColumns += 1; index += 1
                case 0xC0...0xDF:      // 2 字节:U+0080…U+07FF
                    offset += 1; currentColumns += 1; index += 2
                case 0xE0...0xEF:      // 3 字节:U+0800…U+FFFF
                    offset += 1
                    // U+2E80 = E2 BA 80;E2 之前的 3 字节码点(< U+2E80)按 1 列
                    let wide = byte > 0xE2 || (byte == 0xE2 && index + 1 < count && bytes[index + 1] >= 0xBA)
                    currentColumns += wide ? 2 : 1
                    index += 3
                case 0xF0...0xF7:      // 4 字节:代理对,2 个 UTF-16 单元,合计 2 列
                    offset += 2; currentColumns += 2; index += 4
                default:               // 孤立的续字节:忽略(合法 Swift 字符串不会出现)
                    index += 1
                }
            }
        }
    }
}
