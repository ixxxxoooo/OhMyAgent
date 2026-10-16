// @author ixxxxoooo
// xlsx(Office Open XML)读取器:ZIP 解包 → workbook/rels/sharedStrings/styles → 按需解析工作表。
// 全程流式 SAX(XMLParser),只保留显示用文本;不依赖任何第三方库。

import Foundation

/// xlsx 读取错误。
public enum XLSXError: Error, Equatable, LocalizedError {
    case invalidWorkbook(String)
    case sheetIndexOutOfRange

    public var errorDescription: String? {
        switch self {
        case .invalidWorkbook(let reason): return String(localized: "无法读取工作簿:\(reason)")
        case .sheetIndexOutOfRange: return String(localized: "工作表不存在")
        }
    }
}

/// 一个已打开的 xlsx 工作簿(解析共享字符串与样式,工作表按需解析)。
public struct XLSXWorkbook: Sendable {
    /// 工作表(名称与归档内路径)
    public struct SheetRef: Sendable, Equatable {
        public let name: String
        let path: String
    }

    /// 工作表列表(按工作簿内顺序)
    public let sheets: [SheetRef]
    private let archive: ZipArchive
    private let sharedStrings: [String]
    /// 每个单元格样式索引 → 数字样式
    private let styles: [CellNumberStyle]
    private let date1904: Bool

    /// 行数上限(超出截断,避免超大表格占满内存)
    public static let maxRows = 100_000
    /// 列数上限
    public static let maxColumns = 512

    /// - Parameter data: xlsx 文件内容
    /// - Throws: `ZipError` / `XLSXError`
    public init(data: Data) throws {
        let archive = try ZipArchive(data: data)
        self.archive = archive
        guard archive.contains("xl/workbook.xml") else { throw XLSXError.invalidWorkbook("missing workbook.xml") }

        let workbook = WorkbookParser()
        try workbook.parse(try archive.read("xl/workbook.xml"))
        var targets: [String: String] = [:]
        if archive.contains("xl/_rels/workbook.xml.rels") {
            let rels = RelationshipsParser()
            try rels.parse(try archive.read("xl/_rels/workbook.xml.rels"))
            targets = rels.targets
        }
        sheets = workbook.sheets.enumerated().compactMap { offset, sheet in
            let target = targets[sheet.relationshipID] ?? "worksheets/sheet\(offset + 1).xml"
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            return archive.contains(path) ? SheetRef(name: sheet.name, path: path) : nil
        }
        date1904 = workbook.date1904
        if archive.contains("xl/sharedStrings.xml") {
            let strings = SharedStringsParser()
            try strings.parse(try archive.read("xl/sharedStrings.xml"))
            sharedStrings = strings.strings
        } else {
            sharedStrings = []
        }
        if archive.contains("xl/styles.xml") {
            let parser = StylesParser()
            try parser.parse(try archive.read("xl/styles.xml"))
            styles = parser.cellStyles
        } else {
            styles = []
        }
        if sheets.isEmpty { throw XLSXError.invalidWorkbook("no sheets") }
    }

    /// 解析一张工作表。
    /// - Parameter index: 工作表序号(0 起)
    /// - Throws: `XLSXError` / `ZipError`
    public func sheet(at index: Int) throws -> SpreadsheetSheet {
        guard sheets.indices.contains(index) else { throw XLSXError.sheetIndexOutOfRange }
        let ref = sheets[index]
        let parser = SheetParser(sharedStrings: sharedStrings, styles: styles, date1904: date1904)
        try parser.parse(try archive.read(ref.path))
        return parser.result(name: ref.name)
    }
}

// MARK: - XML 解析基础

/// 基于 XMLParser 的一次性解析器基类。
private class XMLReader: NSObject, XMLParserDelegate {
    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = self
        guard parser.parse() else {
            // 代理主动中止(行数超过上限时截断)不是错误
            if let error = parser.parserError as NSError?, error.code == XMLParser.ErrorCode.delegateAbortedParseError.rawValue { return }
            throw XLSXError.invalidWorkbook(parser.parserError?.localizedDescription ?? "XML")
        }
    }
}

/// workbook.xml:工作表名与关系 ID、日期系统。
private final class WorkbookParser: XMLReader {
    struct Sheet { let name: String; let relationshipID: String }
    var sheets: [Sheet] = []
    var date1904 = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch elementName {
        case "sheet":
            if let name = attributeDict["name"], let rid = attributeDict["r:id"] ?? attributeDict["id"] {
                sheets.append(Sheet(name: name, relationshipID: rid))
            }
        case "workbookPr":
            date1904 = attributeDict["date1904"] == "1" || attributeDict["date1904"] == "true"
        default:
            break
        }
    }
}

/// workbook.xml.rels:关系 ID → 目标路径。
private final class RelationshipsParser: XMLReader {
    var targets: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "Relationship", let id = attributeDict["Id"], let target = attributeDict["Target"] { targets[id] = target }
    }
}

/// sharedStrings.xml:共享字符串表(富文本分段拼接,忽略拼音注音)。
private final class SharedStringsParser: XMLReader {
    var strings: [String] = []
    private var current = ""
    private var inText = false
    private var phoneticDepth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch elementName {
        case "si": current = ""
        case "rPh": phoneticDepth += 1
        case "t": inText = phoneticDepth == 0
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "t": inText = false
        case "rPh": phoneticDepth = max(phoneticDepth - 1, 0)
        case "si": strings.append(current)
        default: break
        }
    }
}

/// styles.xml:自定义数字格式与单元格样式(xf)对应的数字样式。
private final class StylesParser: XMLReader {
    var cellStyles: [CellNumberStyle] = []
    private var customCodes: [Int: String] = [:]
    private var inCellXfs = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch elementName {
        case "numFmt":
            if let id = attributeDict["numFmtId"].flatMap(Int.init), let code = attributeDict["formatCode"] { customCodes[id] = code }
        case "cellXfs": inCellXfs = true
        case "xf":
            if inCellXfs {
                let id = attributeDict["numFmtId"].flatMap(Int.init) ?? 0
                cellStyles.append(CellFormat.style(id: id, code: customCodes[id]))
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "cellXfs" { inCellXfs = false }
    }
}

/// 工作表 XML:行、单元格与列宽。
private final class SheetParser: XMLReader {
    private let sharedStrings: [String]
    private let styles: [CellNumberStyle]
    private let date1904: Bool

    private var rows: [[SpreadsheetCell]] = []
    private var columnCount = 0
    private var columnWidths: [Int: Double] = [:]
    private var truncated = false

    // 当前单元格状态
    private var rowIndex = 0
    private var nextColumn = 0
    private var cellColumn = 0
    private var cellType = ""
    private var cellStyle = 0
    private var valueText = ""
    private var inlineText = ""
    private var inValue = false
    private var inInlineText = false
    private var inInline = false
    private var inCell = false

    init(sharedStrings: [String], styles: [CellNumberStyle], date1904: Bool) {
        self.sharedStrings = sharedStrings
        self.styles = styles
        self.date1904 = date1904
    }

    func result(name: String) -> SpreadsheetSheet {
        SpreadsheetSheet(name: name, rows: rows, columnCount: columnCount, columnWidths: columnWidths, truncated: truncated)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch elementName {
        case "col":
            if let min = attributeDict["min"].flatMap(Int.init), let max = attributeDict["max"].flatMap(Int.init), let width = attributeDict["width"].flatMap(Double.init) {
                let upper = Swift.min(max - 1, XLSXWorkbook.maxColumns - 1)
                if min >= 1, min - 1 <= upper { for column in (min - 1)...upper { columnWidths[column] = width } }
            }
        case "row":
            if let r = attributeDict["r"].flatMap(Int.init) { rowIndex = r - 1 } else if !rows.isEmpty { rowIndex = rows.count }
            nextColumn = 0
            if rowIndex >= XLSXWorkbook.maxRows { truncated = true; parser.abortParsing() }
        case "c":
            inCell = true
            if let reference = attributeDict["r"], let parsed = ColumnName.parse(reference: reference) { cellColumn = parsed.column } else { cellColumn = nextColumn }
            nextColumn = cellColumn + 1
            cellType = attributeDict["t"] ?? ""
            cellStyle = attributeDict["s"].flatMap(Int.init) ?? 0
            valueText = ""
            inlineText = ""
        case "v": inValue = inCell
        case "is": inInline = true
        case "t": inInlineText = inInline
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { valueText += string } else if inInlineText { inlineText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v": inValue = false
        case "t": inInlineText = false
        case "is": inInline = false
        case "c":
            inCell = false
            commitCell()
        default: break
        }
    }

    /// 把当前单元格写入结果矩阵。
    private func commitCell() {
        guard rowIndex >= 0, rowIndex < XLSXWorkbook.maxRows else { return }
        guard cellColumn < XLSXWorkbook.maxColumns else { truncated = true; return }
        let cell = makeCell()
        if cell.text.isEmpty { return }
        while rows.count <= rowIndex { rows.append([]) }
        if rows[rowIndex].count <= cellColumn {
            rows[rowIndex].append(contentsOf: Array(repeating: SpreadsheetCell.empty, count: cellColumn + 1 - rows[rowIndex].count))
        }
        rows[rowIndex][cellColumn] = cell
        columnCount = max(columnCount, cellColumn + 1)
    }

    /// 按单元格类型把原始值转成显示文本。
    private func makeCell() -> SpreadsheetCell {
        switch cellType {
        case "s":
            guard let index = Int(valueText.trimmingCharacters(in: .whitespacesAndNewlines)), sharedStrings.indices.contains(index) else { return .empty }
            return SpreadsheetCell(text: sharedStrings[index])
        case "inlineStr":
            return SpreadsheetCell(text: inlineText)
        case "str":
            return SpreadsheetCell(text: valueText)
        case "b":
            return SpreadsheetCell(text: valueText.trimmingCharacters(in: .whitespaces) == "1" ? "TRUE" : "FALSE", kind: .boolean)
        case "e":
            return SpreadsheetCell(text: valueText, kind: .error)
        case "d":
            return SpreadsheetCell(text: valueText)
        default:
            let raw = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return .empty }
            guard let number = Double(raw) else { return SpreadsheetCell(text: raw) }
            let style = styles.indices.contains(cellStyle) ? styles[cellStyle] : .general
            if style == .text { return SpreadsheetCell(text: raw) }
            return SpreadsheetCell(text: CellFormat.format(number, style: style, date1904: date1904), kind: .number)
        }
    }
}
