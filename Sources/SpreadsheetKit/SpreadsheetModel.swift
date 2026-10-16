// @author ixxxxoooo
// 表格数据模型:工作簿里的工作表、行与单元格(纯值类型,可跨线程传递)。

import Foundation

/// 单元格内容类别(决定对齐与显示)。
public enum CellKind: Sendable, Equatable {
    case text, number, boolean, error
}

/// 一个单元格。
public struct SpreadsheetCell: Sendable, Equatable {
    /// 显示文本
    public var text: String
    public var kind: CellKind

    public init(text: String, kind: CellKind = .text) {
        self.text = text
        self.kind = kind
    }

    /// 空单元格。
    public static let empty = SpreadsheetCell(text: "")
}

/// 一张工作表(已解析成行列矩阵)。
public struct SpreadsheetSheet: Sendable, Equatable {
    /// 工作表名
    public var name: String
    /// 行(每行只到最后一个非空单元格;缺失的单元格视为空)
    public var rows: [[SpreadsheetCell]]
    /// 列数(取各行最大列数)
    public var columnCount: Int
    /// 文件里声明的列宽(列索引 → 字符宽度)
    public var columnWidths: [Int: Double]
    /// 因行/列上限被截断
    public var truncated: Bool

    public init(name: String, rows: [[SpreadsheetCell]], columnCount: Int, columnWidths: [Int: Double] = [:], truncated: Bool = false) {
        self.name = name
        self.rows = rows
        self.columnCount = columnCount
        self.columnWidths = columnWidths
        self.truncated = truncated
    }

    /// 取单元格(越界返回空)。
    /// - Parameters:
    ///   - row: 行索引(0 起)
    ///   - column: 列索引(0 起)
    public func cell(row: Int, column: Int) -> SpreadsheetCell {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return .empty }
        return rows[row][column]
    }
}

/// 列索引 ↔ 列字母(0 → A,26 → AA)。
public enum ColumnName {
    /// - Parameter index: 列索引(0 起)
    public static func letters(for index: Int) -> String {
        var n = max(index, 0) + 1
        var result = ""
        while n > 0 {
            let rem = (n - 1) % 26
            result = String(UnicodeScalar(UInt8(65 + rem))) + result
            n = (n - 1) / 26
        }
        return result
    }

    /// 解析单元格引用 `B12` 的列索引与行索引(都从 0 起)。
    /// - Parameter reference: 如 `AB12`
    /// - Returns: (列, 行);格式不合法为 nil
    public static func parse(reference: some StringProtocol) -> (column: Int, row: Int)? {
        var column = 0
        var digits = 0
        var rowValue = 0
        for byte in reference.utf8 {
            if byte >= 65 && byte <= 90 && digits == 0 {
                column = column * 26 + Int(byte - 64)
            } else if byte >= 97 && byte <= 122 && digits == 0 {
                column = column * 26 + Int(byte - 96)
            } else if byte >= 48 && byte <= 57 {
                rowValue = rowValue * 10 + Int(byte - 48)
                digits += 1
            } else {
                return nil
            }
        }
        guard column > 0, digits > 0, rowValue > 0 else { return nil }
        return (column - 1, rowValue - 1)
    }
}
