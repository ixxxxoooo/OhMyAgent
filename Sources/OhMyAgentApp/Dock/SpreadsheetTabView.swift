// @author ixxxxoooo
// xlsx 表格预览标签:原生网格(列头固定、行号、斜纹分隔)、工作表切换、选中单元格在编辑栏显示完整内容、
// 列筛选与排序(类似 Excel 自动筛选:勾选保留的值、搜索、级联候选)。
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
    /// 筛选/排序状态与由它算出的可见行(原始行索引);状态变化时重算,不在 body 里计算
    @State private var filterState = SheetFilterState()
    @State private var visibleRows: [Int] = []
    /// 筛选模式:列头显示筛选按钮(类似 Excel 的「筛选」开关)
    @State private var filterMode = false
    /// 查找(⌘F):状态模型;可见行/工作表变化时递增 `findRevision` 触发重新匹配
    @State private var find = TableFindState()
    @State private var findRevision = 0
    @Environment(\.tabIsActive) private var tabActive

    private enum Phase: Equatable { case loading, ready, failed(String) }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                OMSpinner(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                OMEmptyState {
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
        .onChange(of: filterState) { _, _ in refreshVisibleRows() }
        .task(id: FindKey(query: find.query, revision: findRevision, isOpen: find.isOpen)) { await refreshMatches() }
        .onChange(of: find.current) { _, new in
            if let new { selection = CellPosition(row: new.row, column: new.column) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .omTableFind)) { note in
            guard tabActive, phase == .ready, let action = TableFindRouter.action(from: note) else { return }
            find.handle(action)
        }
    }

    /// 查找任务的触发键:关键词、可见行/工作表版本、查找条开关任一变化都重新匹配。
    private struct FindKey: Equatable {
        let query: String
        let revision: Int
        let isOpen: Bool
    }

    /// 在可见行里重新匹配(防抖后在后台线程算,保持当前选中的匹配)。
    private func refreshMatches() async {
        guard find.isOpen, let sheet else { find.setMatches([], keeping: nil); return }
        let query = find.query
        let rows = visibleRows
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let found = await Task.detached(priority: .userInitiated) {
            TableSearch.matches(query: query, rows: rows, columnCount: sheet.columnCount) { sheet.cell(row: $0, column: $1).text }
        }.value
        guard !Task.isCancelled else { return }
        find.setMatches(found, keeping: find.current)
    }

    /// 按当前筛选/排序重算可见行。
    private func refreshVisibleRows() {
        guard let sheet else { visibleRows = []; return }
        visibleRows = SheetFilter.visibleRows(in: sheet, state: filterState)
        findRevision += 1
    }

    /// 载入或切换工作表后重置筛选状态。
    private func resetFilters(for sheet: SpreadsheetSheet?) {
        filterState = SheetFilterState()
        visibleRows = sheet.map { SheetFilter.visibleRows(in: $0, state: SheetFilterState()) } ?? []
        findRevision += 1
    }

    @ViewBuilder
    private var content: some View {
        if let sheet, let workbook {
            VStack(spacing: 0) {
                formulaBar(sheet)
                Divider()
                if find.isOpen {
                    TableFindBar(state: find)
                    Divider()
                }
                SpreadsheetGrid(sheet: sheet, visibleRows: visibleRows, filterMode: filterMode, filterState: $filterState, selection: $selection, matches: find.matchSet, current: find.current)
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
            filterControls
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("编辑栏")
    }

    /// 编辑栏右侧的筛选控件:筛选开关、首行表头开关、清除全部筛选。
    private var filterControls: some View {
        HStack(spacing: 4) {
            Button { find.isOpen ? find.close() : find.show() } label: {
                Image.om("search", size: 12)
            }
            .buttonStyle(find.isOpen ? .omSecondary : .omIcon)
            .omTooltip("查找 (⌘F)")
            .accessibilityLabel("查找")
            .accessibilityAddTraits(find.isOpen ? .isSelected : [])
            if filterState.isActive {
                Button {
                    filterState.clearFilters()
                    filterState.sort = nil
                } label: {
                    Label("清除筛选", om: "funnel-x", size: 12)
                }
                .buttonStyle(.omPlain)
                .omTooltip("清除全部筛选与排序")
            }
            if filterMode {
                Button { filterState.firstRowIsHeader.toggle() } label: {
                    Label(filterState.firstRowIsHeader ? String(localized: "首行为表头") : String(localized: "首行为数据"), om: filterState.firstRowIsHeader ? "square-check" : "square", size: 12)
                }
                .buttonStyle(.omPlain)
                .omTooltip("首行作为表头:始终显示在最前,不参与筛选与排序")
            }
            Button {
                filterMode.toggle()
                if !filterMode { filterState = SheetFilterState(firstRowIsHeader: filterState.firstRowIsHeader) }
            } label: {
                Label("筛选", om: "funnel", size: 12)
            }
            .buttonStyle(filterMode ? .omSecondary : .omPlain)
            .omTooltip(filterMode ? "关闭筛选(清除全部条件)" : "开启列筛选")
            .accessibilityAddTraits(filterMode ? .isSelected : [])
        }
    }

    /// 底栏:工作表切换 + 行列统计。
    private func footer(_ sheet: SpreadsheetSheet, workbook: XLSXWorkbook) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(workbook.sheets.enumerated()), id: \.offset) { index, ref in
                        Button { select(sheet: index) } label: {
                            Text(ref.name)
                                .font(OMFonts.small.weight(index == sheetIndex ? .medium : .regular))
                                .lineLimit(1)
                                .padding(.horizontal, 10).frame(height: 22)
                                .background(index == sheetIndex ? OMColors.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
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
            if visibleRows.count != sheet.rows.count {
                Text("显示 \(visibleRows.count.formatted()) / \(sheet.rows.count.formatted()) 行")
                    .font(OMFonts.caption).foregroundStyle(OMColors.accent)
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
            filterMode = false
            resetFilters(for: result.1)
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
            if sheetIndex == index {
                sheet = parsed ?? sheet
                filterMode = false
                resetFilters(for: sheet)
            }
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
    /// 可见行(原始行索引,已按筛选与排序处理)
    let visibleRows: [Int]
    let filterMode: Bool
    @Binding var filterState: SheetFilterState
    @Binding var selection: CellPosition?
    /// 查找命中的单元格与当前命中(高亮并滚动到可见)
    let matches: Set<TableMatch>
    let current: TableMatch?

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
        ScrollViewReader { proxy in
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(visibleRows.isEmpty && sheet.rows.isEmpty ? [0] : visibleRows, id: \.self) { row in
                        GridRow(sheet: sheet, row: row, widths: columnWidths, selection: $selection, matches: matches, current: current)
                    }
                    if visibleRows.count <= (filterState.firstRowIsHeader ? 1 : 0), !sheet.rows.isEmpty {
                        Text("没有符合筛选条件的行")
                            .font(OMFonts.small).foregroundStyle(OMColors.tertiaryText)
                            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                    }
                } header: {
                    HeaderRow(sheet: sheet, widths: columnWidths, filterMode: filterMode, filterState: $filterState)
                }
            }
        }
        .onChange(of: current) { _, new in
            guard let new else { return }
            // 行是懒加载的:先滚到所在行,行创建出来后再把该列滚进可视区
            withAnimation(nil) { proxy.scrollTo(new.row, anchor: .center) }
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation(nil) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        }
    }
}

/// 列头行(A、B、C…);筛选模式下每列右侧出现筛选按钮,有筛选/排序的列常显。
private struct HeaderRow: View {
    let sheet: SpreadsheetSheet
    let widths: [CGFloat]
    let filterMode: Bool
    @Binding var filterState: SheetFilterState

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: GridMetrics.rowNumberWidth, height: GridMetrics.headerHeight)
            ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                HeaderCell(sheet: sheet, column: column, width: width, filterMode: filterMode, filterState: $filterState)
            }
        }
        .background(OMColors.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(OMColors.hairline).frame(height: 0.5) }
    }
}

/// 单个列头:列字母 + 筛选按钮(点击弹出筛选面板)。
private struct HeaderCell: View {
    let sheet: SpreadsheetSheet
    let column: Int
    let width: CGFloat
    let filterMode: Bool
    @Binding var filterState: SheetFilterState
    @State private var open = false
    @State private var hovering = false

    private var isFiltered: Bool { filterState.isFiltered(column: column) }
    private var sortedHere: SheetSort? { filterState.sort.flatMap { $0.column == column ? $0 : nil } }
    private var showsButton: Bool { filterMode || isFiltered || sortedHere != nil }
    private var letters: String { ColumnName.letters(for: column) }

    var body: some View {
        ZStack {
            Text(letters)
                .font(OMFonts.caption)
                .foregroundStyle(isFiltered || sortedHere != nil ? OMColors.accent : OMColors.secondaryText)
            if showsButton {
                HStack {
                    Spacer(minLength: 0)
                    Button { open.toggle() } label: {
                        HStack(spacing: 1) {
                            if let sort = sortedHere { Image.om(sort.ascending ? "arrow-up" : "arrow-down", size: 9) }
                            Image.om(isFiltered ? "funnel" : "chevron-down", size: 10)
                        }
                        .frame(minWidth: 18, minHeight: 18)
                        .background(open || hovering ? OMColors.pressedFill : Color.clear, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isFiltered || sortedHere != nil ? OMColors.accent : OMColors.tertiaryText)
                    .onHover { hovering = $0 }
                    .omTooltip(isFiltered ? "已筛选:点击修改" : "筛选此列")
                    .accessibilityLabel(String(localized: "筛选列 \(letters)"))
                    .omCustomPicker(isPresented: $open, placement: .below, width: 260) {
                        ColumnFilterPanel(sheet: sheet, column: column, filterState: $filterState) { open = false }
                    }
                }
                .padding(.trailing, 3)
            }
        }
        .frame(width: width, height: GridMetrics.headerHeight)
        .overlay(alignment: .trailing) { Rectangle().fill(OMColors.hairline).frame(width: 0.5) }
    }
}

/// 列筛选面板:排序、搜索、全选、按值勾选(带出现次数),改动即时生效。
private struct ColumnFilterPanel: View {
    let sheet: SpreadsheetSheet
    let column: Int
    @Binding var filterState: SheetFilterState
    let onClose: () -> Void
    /// 本列候选值(只受其他列筛选影响,打开面板时算一次)
    @State private var values: [ColumnValue]
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    init(sheet: SpreadsheetSheet, column: Int, filterState: Binding<SheetFilterState>, onClose: @escaping () -> Void) {
        self.sheet = sheet
        self.column = column
        _filterState = filterState
        self.onClose = onClose
        _values = State(initialValue: SheetFilter.distinctValues(in: sheet, column: column, state: filterState.wrappedValue))
    }

    /// 当前勾选的值(没有筛选时为全部)。
    private var allowed: Set<String> { filterState.filters[column] ?? Set(values.map(\.text)) }

    /// 搜索过滤后的候选值。
    private var matches: [ColumnValue] {
        let key = query.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return values }
        return values.filter { displayName($0).localizedCaseInsensitiveContains(key) }
    }

    private func displayName(_ value: ColumnValue) -> String { value.text.isEmpty ? String(localized: "(空白)") : value.text }

    /// 标题:列字母 + 首行表头文本(首行作为表头时)。
    private var title: String {
        let letters = ColumnName.letters(for: column)
        let header = filterState.firstRowIsHeader ? sheet.cell(row: 0, column: column).text : ""
        return header.isEmpty ? String(localized: "列 \(letters)") : String(localized: "列 \(letters) · \(header)")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: title)
                .font(OMFonts.small.weight(.medium)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            sortRow
            Divider()
            HStack(spacing: 6) {
                Image.om("search", size: 12).foregroundStyle(OMColors.tertiaryText)
                TextField("搜索", text: $query)
                    .textFieldStyle(.plain).font(OMFonts.small)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 12).frame(height: 30)
            Divider()
            valueList
            Divider()
            footer
        }
        .onKeyPress(.escape) { onClose(); return .handled }
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            searchFocused = true
        }
    }

    private var sortRow: some View {
        HStack(spacing: 6) {
            sortButton(ascending: true, icon: "arrow-up-a-z", title: "升序")
            sortButton(ascending: false, icon: "arrow-down-z-a", title: "降序")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private func sortButton(ascending: Bool, icon: String, title: LocalizedStringKey) -> some View {
        let active = filterState.sort == SheetSort(column: column, ascending: ascending)
        return Button {
            filterState.sort = active ? nil : SheetSort(column: column, ascending: ascending)
        } label: {
            Label(title, om: icon, size: 12)
        }
        .buttonStyle(active ? .omSecondary : .omPlain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var valueList: some View {
        let shown = matches
        let checked = allowed
        let allChecked = !shown.isEmpty && shown.allSatisfy { checked.contains($0.text) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if shown.isEmpty {
                    Text("没有匹配项").font(OMFonts.small).foregroundStyle(OMColors.secondaryText).padding(12)
                } else {
                    row(checked: allChecked, text: query.isEmpty ? String(localized: "(全选)") : String(localized: "(全选搜索结果)"), count: nil, emphasized: true) {
                        setAll(shown, checked: !allChecked)
                    }
                    ForEach(shown) { value in
                        row(checked: checked.contains(value.text), text: displayName(value), count: value.count, emphasized: false) {
                            SheetFilter.toggle(value.text, column: column, available: values, in: &filterState)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(checked: Bool, text: String, count: Int?, emphasized: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image.om(checked ? "square-check" : "square", size: 14)
                    .foregroundStyle(checked ? OMColors.accent : OMColors.tertiaryText)
                Text(verbatim: text).font(emphasized ? OMFonts.small.weight(.medium) : OMFonts.small).lineLimit(1)
                Spacer(minLength: 4)
                if let count { Text("\(count)").font(OMFonts.caption).monospacedDigit().foregroundStyle(OMColors.tertiaryText) }
            }
            .padding(.horizontal, 12).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    /// 勾选或取消勾选一组值(搜索结果)。
    private func setAll(_ group: [ColumnValue], checked: Bool) {
        var next = allowed
        for value in group { if checked { next.insert(value.text) } else { next.remove(value.text) } }
        SheetFilter.setAllowed(next, column: column, available: values, in: &filterState)
    }

    private var footer: some View {
        HStack {
            Button("清除筛选") { filterState.clearFilter(column: column) }
                .buttonStyle(.omPlain)
                .disabled(!filterState.isFiltered(column: column))
            Spacer()
            Button("完成", action: onClose).buttonStyle(.omPrimary)
        }
        .padding(.horizontal, 10).frame(height: 38)
    }
}

/// 数据行:行号 + 单元格。
private struct GridRow: View {
    let sheet: SpreadsheetSheet
    let row: Int
    let widths: [CGFloat]
    @Binding var selection: CellPosition?
    let matches: Set<TableMatch>
    let current: TableMatch?

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
        let position = TableMatch(row: row, column: column)
        let isCurrentMatch = current == position
        let isMatch = isCurrentMatch || matches.contains(position)
        return Text(value.text)
            .font(OMFonts.small)
            .foregroundStyle(value.kind == .error ? OMColors.danger : OMColors.primaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(width: width, height: GridMetrics.rowHeight, alignment: value.kind == .number ? .trailing : .leading)
            .background(isCurrentMatch ? OMColors.warning.opacity(0.55) : isMatch ? OMColors.warning.opacity(0.25) : isSelected ? OMColors.selectedFill : Color.clear)
            .id(position)
            .overlay { if isSelected { Rectangle().strokeBorder(OMColors.accent, lineWidth: 1.5) } }
            .overlay(alignment: .trailing) { Rectangle().fill(OMColors.hairline.opacity(0.6)).frame(width: 0.5) }
            .contentShape(Rectangle())
            .onTapGesture { selection = CellPosition(row: row, column: column) }
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
