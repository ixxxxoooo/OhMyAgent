// @author ixxxxoooo
// 粘性滚动(sticky scroll)与缩略图用的纯函数:按缩进推断「包含某行的代码块头」、缩略图行采样。
// 不依赖语法树:以缩进为主、行尾 `{ ( [ :` 判断块开头,对所有语言都能给出合理结果;无视图。

import Foundation

public enum EditorScopes {
    /// 一行的缩进列数(制表符按 `tabWidth` 列计),空白行返回 nil。
    /// - Parameters:
    ///   - line: 行文本
    ///   - tabWidth: 制表符宽度
    public static func indent(of line: String, tabWidth: Int = 4) -> Int? {
        var columns = 0
        for char in line {
            if char == " " { columns += 1 } else if char == "\t" { columns += tabWidth } else { return columns }
        }
        return nil
    }

    /// 该行是否像代码块的开头(以 `{ ( [` 结尾,或以 `:` 结尾且不是注释)。
    /// - Parameter line: 行文本
    public static func opensBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("*") || trimmed.hasPrefix("--") { return false }
        return last == "{" || last == "(" || last == "[" || last == ":"
    }

    /// 求包含 `topLine` 的外层块头行(由外到内),用于粘性滚动。
    /// - Parameters:
    ///   - topLine: 视口第一行(0 起始)
    ///   - limit: 最多返回几层
    ///   - scanLimit: 向上最多扫描多少行
    ///   - lineCount: 总行数
    ///   - line: 取某行文本的闭包(越界返回 nil)
    /// - Returns: 块头行号(0 起始,升序);都小于 `topLine`
    public static func enclosing(topLine: Int, limit: Int = 3, scanLimit: Int = 3000, lineCount: Int, line: (Int) -> String?) -> [Int] {
        guard topLine > 0, topLine < lineCount, limit > 0 else { return [] }
        // 基准缩进:从顶行起向下找第一个非空行(顶行本身可能是空行)
        var current: Int?
        var probe = topLine
        while probe < min(lineCount, topLine + 50) {
            if let text = line(probe), let columns = indent(of: text) { current = columns; break }
            probe += 1
        }
        guard var level = current else { return [] }
        var result: [Int] = []
        var index = topLine - 1
        let stop = max(0, topLine - scanLimit)
        while index >= stop, result.count < limit, level > 0 {
            if let text = line(index), let columns = indent(of: text), columns < level {
                if opensBlock(text) { result.append(index) }
                level = columns
            }
            index -= 1
        }
        return result.reversed()
    }

    /// 缩略图的行采样:把 `lineCount` 行映射到 `rows` 个像素行,每个像素行取其覆盖的第一行。
    /// - Parameters:
    ///   - lineCount: 总行数
    ///   - rows: 可绘制的像素行数
    /// - Returns: 每个像素行对应的行号(0 起始);行数不足时一行一格
    public static func minimapLines(lineCount: Int, rows: Int) -> [Int] {
        guard lineCount > 0, rows > 0 else { return [] }
        if lineCount <= rows { return Array(0..<lineCount) }
        return (0..<rows).map { min(lineCount - 1, $0 * lineCount / rows) }
    }
}
