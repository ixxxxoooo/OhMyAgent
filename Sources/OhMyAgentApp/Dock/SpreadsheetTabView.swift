// @author ixxxxoooo
// xlsx 表格预览标签:原生网格(列头固定、行号、斜纹分隔)、工作表切换、选中单元格在编辑栏显示完整内容。
// 数据由 SpreadsheetKit 在后台线程解析;网格按行懒加载,十万行也能流畅滚动。

import AppKit
import DesignSystem
import IconKit
import OMLog
import SpreadsheetKit
import SwiftUI

/// 表格网格布局参数(统一在这里,视图里不写魔法数字)。
private enum GridMetrics {
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 24
    static let rowNumberWidth: CGFloat = 52
    static let minColumnWidth: CGFloat = 56
    static let maxColumnWidth: CGFloat = 360
    /// 一个字符的近似宽度(按等宽估算列宽)
    static let charWidth: CGFloat = 7.2
    /// 估算列宽时最多采样的行数
    static let sampleRows = 300
}

/// xlsx 文件标签。
struct SpreadsheetTabView: View {
    let path: String
    @State private var workbook: XLSXWorkbook?
    @State private var sheet: SpreadsheetSheet?
    @State private var sheetIndex = 0
    @State private var phase: Phase = .loading
    @State private var selection: CellPosition?

    private enum Phase: Equatable { case loading, ready, failed(String) }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("无法打开表格", om: "file-text", size: 28)
                } description: {
                    Text(message)
                }
            case .ready:
                content
            }
        }
        .background(OMColors.surface)
        .task(id: path) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let sheet, let workbook {
            VStack(spacing: 0) {
                formulaBar(sheet)
                Divider()
                SpreadsheetGrid(sheet: sheet, selection: $selection)
                Divider()
                footer(sheet, workbook: workbook)
            }
        }
    }

    /// 编辑栏:选中单元格的引用与完整文本(可选中复制)。
    private func formulaBar(_ sheet: SpreadsheetSheet) -> some View {
        HStack(spacing: 10) {
            Text(selection.map { "\(ColumnName.letters(for: $0.column))\($0.row + 1)" } ?? "—")
                .font(OMFonts.monoSmall)
                .foregroundStyle(OMColors.secondaryText)
                .frame(width: 56, alignment: .leading)
            Divider().frame(height: 14)
            Text(selection.map { sheet.cell(row: $0.row, column: $0.column).text } ?? "")
                .font(OMFonts.small)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("编辑栏")
    }

    /// 底栏:工作表切换 + 行列统计。
    private func footer(_ sheet: SpreadsheetSheet, workbook: XLSXWorkbook) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(workbook.sheets.enumerated()), id: \.offset) { index, ref in
                        Button { select(sheet: index) } label: {
                            Text(ref.name)
                                .font(OMFonts.small.weight(index == sheetIndex ? .semibold : .regular))
                                .lineLimit(1)
                                .padding(.horizontal, 10).frame(height: 22)
                                .background(index == sheetIndex ? OMColors.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == sheetIndex ? OMColors.accent : OMColors.secondaryText)
                        .accessibilityLabel(ref.name)
                        .accessibilityAddTraits(index == sheetIndex ? .isSelected : [])
                    }
                }
            }
            Spacer(minLength: 8)
            if sheet.truncated {
                Text("仅显示前 \(XLSXWorkbook.maxRows.formatted()) 行 / \(XLSXWorkbook.maxColumns.formatted()) 列")
                    .font(OMFonts.caption).foregroundStyle(OMColors.warning)
            }
            Text("\(sheet.rows.count.formatted()) 行 × \(sheet.columnCount.formatted()) 列")
                .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    /// 后台读取并解析第一张工作表。
    private func load() async {
        phase = .loading
        let target = path
        let started = ContinuousClock.now
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> (XLSXWorkbook, SpreadsheetSheet) in
                let data = try Data(contentsOf: URL(fileURLWithPath: target), options: .mappedIfSafe)
                let book = try XLSXWorkbook(data: data)
                return (book, try book.sheet(at: 0))
            }.value
            workbook = result.0
            sheet = result.1
            sheetIndex = 0
            selection = nil
            phase = .ready
            Log.ui.info("打开表格", ["file": (path as NSString).lastPathComponent, "rows": "\(result.1.rows.count)", "ms": "\(started.duration(to: .now) / .milliseconds(1))"])
        } catch {
            Log.ui.error("打开表格失败", error: error, ["file": (path as NSString).lastPathComponent])
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// 切换工作表(后台解析)。
    private func select(sheet index: Int) {
        guard let workbook, index != sheetIndex else { return }
        sheetIndex = index
        selection = nil
        Task {
            let parsed = await Task.detached(priority: .userInitiated) { try? workbook.sheet(at: index) }.value
            if sheetIndex == index { sheet = parsed ?? sheet }
        }
    }
}

/// 选中的单元格位置。
private struct CellPosition: Equatable {
    let row: Int
    let column: Int
}

/// 网格:列头固定在顶部,行按需创建。
private struct SpreadsheetGrid: View {
    let sheet: SpreadsheetSheet
    @Binding var selection: CellPosition?

    /// 各列宽度:文件声明优先,否则按前若干行内容估算。
    private var widths: [CGFloat] {
        (0..<max(sheet.columnCount, 1)).map { column in
            if let declared = sheet.columnWidths[column] {
                return min(max(CGFloat(declared) * GridMetrics.charWidth + 8, GridMetrics.minColumnWidth), GridMetrics.maxColumnWidth)
            }
            var longest = ColumnName.letters(for: column).count
            for row in sheet.rows.prefix(GridMetrics.sampleRows) where row.indices.contains(column) {
                // 中日韩字符按两个宽度估算
                let width = row[column].text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 2 : 1) }
                longest = max(longest, width)
            }
            return min(max(CGFloat(longest) * GridMetrics.charWidth + 16, GridMetrics.minColumnWidth), GridMetrics.maxColumnWidth)
        }
    }

    var body: some View {
        let columnWidths = widths
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(0..<max(sheet.rows.count, 1), id: \.self) { row in
                        GridRow(sheet: sheet, row: row, widths: columnWidths, selection: $selection)
                    }
                } header: {
                    HeaderRow(widths: columnWidths)
                }
            }
        }
    }
}

/// 列头行(A、B、C…)。
private struct HeaderRow: View {
    let widths: [CGFloat]

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: GridMetrics.rowNumberWidth, height: GridMetrics.headerHeight)
            ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                Text(ColumnName.letters(for: column))
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
                    .frame(width: width, height: GridMetrics.headerHeight)
                    .overlay(alignment: .trailing) { Rectangle().fill(OMColors.hairline).frame(width: 0.5) }
            }
        }
        .background(OMColors.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(OMColors.hairline).frame(height: 0.5) }
    }
}

/// 数据行:行号 + 单元格。
private struct GridRow: View {
    let sheet: SpreadsheetSheet
    let row: Int
    let widths: [CGFloat]
    @Binding var selection: CellPosition?

    var body: some View {
        HStack(spacing: 0) {
            Text("\(row + 1)")
                .font(OMFonts.caption.monospacedDigit())
                .foregroundStyle(OMColors.tertiaryText)
                .frame(width: GridMetrics.rowNumberWidth, height: GridMetrics.rowHeight)
                .background(OMColors.sidebar)
            ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                cell(column: column, width: width)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(OMColors.hairline.opacity(0.6)).frame(height: 0.5) }
    }

    private func cell(column: Int, width: CGFloat) -> some View {
        let value = sheet.cell(row: row, column: column)
        let isSelected = selection == CellPosition(row: row, column: column)
        return Text(value.text)
            .font(OMFonts.small)
            .foregroundStyle(value.kind == .error ? OMColors.danger : OMColors.primaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(width: width, height: GridMetrics.rowHeight, alignment: value.kind == .number ? .trailing : .leading)
            .background(isSelected ? OMColors.accent.opacity(0.12) : Color.clear)
            .overlay { if isSelected { Rectangle().strokeBorder(OMColors.accent, lineWidth: 1.5) } }
            .overlay(alignment: .trailing) { Rectangle().fill(OMColors.hairline.opacity(0.6)).frame(width: 0.5) }
            .contentShape(Rectangle())
            .onTapGesture { selection = CellPosition(row: row, column: column) }
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
