// @author ixxxxoooo
// xlsx 读取测试:ZIP 解包(存储/deflate)、共享字符串、数字与日期格式、列引用、截断。
// 测试在内存里现拼 xlsx,不依赖二进制样例文件。

import Foundation
import Testing
@testable import SpreadsheetKit

/// 生成 ZIP(用 deflate 或存储);CRC 填 0(读取器不校验)。
private func makeZip(_ files: [(String, String)], deflate: Bool = true) throws -> Data {
    var out = Data()
    var central = Data()
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
    for (name, text) in files {
        let raw = Data(text.utf8)
        let stored: Data
        let method: Int
        if deflate, !raw.isEmpty {
            stored = try (raw as NSData).compressed(using: .zlib) as Data
            method = 8
        } else {
            stored = raw
            method = 0
        }
        let nameBytes = Data(name.utf8)
        let offset = out.count
        out.append(contentsOf: le32(0x0403_4B50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0) + le32(0) + le32(stored.count) + le32(raw.count) + le16(nameBytes.count) + le16(0))
        out.append(nameBytes)
        out.append(stored)
        central.append(contentsOf: le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0) + le32(0) + le32(stored.count) + le32(raw.count) + le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset))
        central.append(nameBytes)
    }
    let directoryOffset = out.count
    out.append(central)
    out.append(contentsOf: le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(directoryOffset) + le16(0))
    return out
}

private let workbookXML = """
<?xml version="1.0"?><workbook xmlns="x" xmlns:r="r"><workbookPr/><sheets>
<sheet name="销售" sheetId="1" r:id="rId1"/><sheet name="Sheet2" sheetId="2" r:id="rId2"/></sheets></workbook>
"""
private let relsXML = """
<?xml version="1.0"?><Relationships>
<Relationship Id="rId1" Type="t" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="t" Target="/xl/worksheets/sheet2.xml"/></Relationships>
"""
private let stylesXML = """
<?xml version="1.0"?><styleSheet><numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy&quot;年&quot;m&quot;月&quot;d&quot;日&quot;"/></numFmts>
<cellStyleXfs count="1"><xf numFmtId="14"/></cellStyleXfs>
<cellXfs count="5"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="10"/><xf numFmtId="4"/><xf numFmtId="164"/></cellXfs></styleSheet>
"""
private let stringsXML = """
<?xml version="1.0"?><sst><si><t>名称</t></si><si><r><t>富</t></r><r><t>文本</t></r><rPh><t>ふ</t></rPh></si><si><t xml:space="preserve"> 带空格 </t></si></sst>
"""
private let sheet1XML = """
<?xml version="1.0"?><worksheet><cols><col min="1" max="2" width="20"/></cols><sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="D1" t="s"><v>2</v></c></row>
<row r="3"><c r="A3"><v>12</v></c><c r="B3" s="1"><v>45292</v></c><c r="C3" s="2"><v>0.256</v></c><c r="D3" s="3"><v>1234567.891</v></c></row>
<row r="4"><c r="A4" t="b"><v>1</v></c><c r="B4" t="inlineStr"><is><t>内联</t></is></c><c r="C4" t="e"><v>#DIV/0!</v></c><c r="D4" t="str"><v>公式文本</v></c><c r="E4" s="4"><v>45292.5</v></c></row>
<row r="5"><c r="A5"><v>0.1</v></c><c r="B5"><f>A5*2</f><v>0.30000000000000004</v></c></row>
</sheetData></worksheet>
"""

private func makeWorkbook(deflate: Bool = true) throws -> Data {
    try makeZip([
        ("xl/workbook.xml", workbookXML), ("xl/_rels/workbook.xml.rels", relsXML), ("xl/styles.xml", stylesXML),
        ("xl/sharedStrings.xml", stringsXML), ("xl/worksheets/sheet1.xml", sheet1XML),
        ("xl/worksheets/sheet2.xml", "<worksheet><sheetData><row r=\"1\"><c r=\"A1\"><v>7</v></c></row></sheetData></worksheet>"),
    ], deflate: deflate)
}

@Suite("xlsx 读取")
struct SpreadsheetKitTests {
    @Test("ZIP:deflate 与存储两种条目都能读出")
    func zipRoundTrip() throws {
        for deflate in [true, false] {
            let zip = try ZipArchive(data: makeZip([("a.txt", "你好,世界"), ("dir/b.txt", "second")], deflate: deflate))
            #expect(String(decoding: try zip.read("a.txt"), as: UTF8.self) == "你好,世界")
            #expect(String(decoding: try zip.read("dir/b.txt"), as: UTF8.self) == "second")
        }
        #expect(throws: ZipError.self) { try ZipArchive(data: Data("not a zip".utf8)) }
    }

    @Test("工作簿:工作表名、相对/绝对关系路径")
    func sheets() throws {
        let book = try XLSXWorkbook(data: makeWorkbook())
        #expect(book.sheets.map(\.name) == ["销售", "Sheet2"])
        let second = try book.sheet(at: 1)
        #expect(second.cell(row: 0, column: 0).text == "7")
        #expect(throws: XLSXError.self) { try book.sheet(at: 5) }
    }

    @Test("单元格:共享字符串(富文本拼接、忽略注音)、空行、稀疏列、列宽")
    func cells() throws {
        let sheet = try XLSXWorkbook(data: makeWorkbook()).sheet(at: 0)
        #expect(sheet.cell(row: 0, column: 0).text == "名称")
        #expect(sheet.cell(row: 0, column: 1).text == "富文本")
        #expect(sheet.cell(row: 0, column: 3).text == " 带空格 ")
        #expect(sheet.cell(row: 1, column: 0) == .empty)   // 第 2 行不存在
        #expect(sheet.columnCount == 5)
        #expect(sheet.columnWidths[0] == 20 && sheet.columnWidths[1] == 20)
    }

    @Test("数字格式:整数、日期、百分比、千分位、自定义日期、布尔、错误、内联与公式字符串")
    func numberFormats() throws {
        let sheet = try XLSXWorkbook(data: makeWorkbook()).sheet(at: 0)
        #expect(sheet.cell(row: 2, column: 0).text == "12")
        #expect(sheet.cell(row: 2, column: 1).text == "2024-01-01")
        #expect(sheet.cell(row: 2, column: 2).text == "25.60%")
        #expect(sheet.cell(row: 2, column: 3).text == "1,234,567.89")
        #expect(sheet.cell(row: 2, column: 0).kind == .number)
        #expect(sheet.cell(row: 3, column: 0) == SpreadsheetCell(text: "TRUE", kind: .boolean))
        #expect(sheet.cell(row: 3, column: 1).text == "内联")
        #expect(sheet.cell(row: 3, column: 2).kind == .error)
        #expect(sheet.cell(row: 3, column: 3).text == "公式文本")
        #expect(sheet.cell(row: 3, column: 4).text == "2024-01-01 12:00:00")
        #expect(sheet.cell(row: 4, column: 0).text == "0.1")
        #expect(sheet.cell(row: 4, column: 1).text == "0.3")   // 常规格式最多 15 位有效数字
    }

    @Test("日期换算:1900 系统的闰年错误与 1904 系统")
    func dates() {
        func day(_ serial: Double, date1904: Bool = false) -> String { CellFormat.format(serial, style: .date(hasDate: true, hasTime: false), date1904: date1904) }
        #expect(day(1) == "1900-01-01")
        #expect(day(59) == "1900-02-28")
        #expect(day(61) == "1900-03-01")
        #expect(day(25569) == "1970-01-01")
        #expect(day(44927) == "2023-01-01")
        #expect(day(0, date1904: true) == "1904-01-01")
        #expect(day(24107, date1904: true) == "1970-01-01")
    }

    @Test("列引用换算")
    func columnNames() {
        #expect(ColumnName.letters(for: 0) == "A" && ColumnName.letters(for: 25) == "Z" && ColumnName.letters(for: 26) == "AA" && ColumnName.letters(for: 701) == "ZZ" && ColumnName.letters(for: 702) == "AAA")
        #expect(ColumnName.parse(reference: "AB12")?.column == 27 && ColumnName.parse(reference: "AB12")?.row == 11)
        #expect(ColumnName.parse(reference: "12") == nil && ColumnName.parse(reference: "A") == nil)
    }

    @Test("自定义格式识别")
    func customCodes() {
        #expect(CellFormat.style(id: 165, code: "yyyy-mm-dd hh:mm") == .date(hasDate: true, hasTime: true))
        #expect(CellFormat.style(id: 166, code: "0.00%") == .fixed(decimals: 2, thousands: false, percent: true))
        #expect(CellFormat.style(id: 167, code: "#,##0.0_);[Red](#,##0.0)") == .fixed(decimals: 1, thousands: true, percent: false))
        #expect(CellFormat.style(id: 168, code: "0.00E+00") == .scientific(decimals: 2))
        #expect(CellFormat.style(id: 169, code: "@") == .text)
        #expect(CellFormat.style(id: 170, code: "General") == .general)
    }

    @Test("超过行数上限时截断并标记")
    func truncation() throws {
        let rows = (1...(XLSXWorkbook.maxRows + 5)).map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c></row>" }.joined()
        let data = try makeZip([
            ("xl/workbook.xml", workbookXML), ("xl/_rels/workbook.xml.rels", relsXML),
            ("xl/worksheets/sheet1.xml", "<worksheet><sheetData>\(rows)</sheetData></worksheet>"),
            ("xl/worksheets/sheet2.xml", "<worksheet/>"),
        ])
        let sheet = try XLSXWorkbook(data: data).sheet(at: 0)
        #expect(sheet.truncated)
        #expect(sheet.rows.count == XLSXWorkbook.maxRows)
    }
}
