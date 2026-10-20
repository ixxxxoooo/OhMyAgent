// @author ixxxxoooo
// 日志表格:AppKit `NSTableView` 实现的日志列表(固定行高、复用单元格、尾部增量插入)。
// 取代 SwiftUI `List`:数千行日志高频追加时不再整表重算差异,只插入新行并按需贴底。

import AppKit
import DesignSystem
import OMLog
import SwiftUI

/// 日志表格(只读,可多选,⌘C 复制所选行)。
struct LogTableView: NSViewRepresentable {
    /// 当前要展示的(已过滤)日志
    let rows: [LogEntry]
    /// 是否自动贴底
    let follow: Bool

    func makeCoordinator() -> LogTableCoordinator { LogTableCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LogNSTableView()
        table.headerView = nil
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true
        table.gridStyleMask = []
        table.focusRingType = .none
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: LogTableCoordinator.columnID)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        context.coordinator.observeTheme()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(rows: rows, follow: follow)
    }
}

/// 支持 ⌘C 的表格。
final class LogNSTableView: NSTableView {
    /// 复制所选行文本。
    @objc func copy(_ sender: Any?) {
        guard let source = dataSource as? LogTableCoordinator else { return }
        let text = selectedRowIndexes.compactMap { source.rows.indices.contains($0) ? source.rows[$0].line : nil }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 表格数据源与增量更新。
@MainActor
final class LogTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let columnID = NSUserInterfaceItemIdentifier("log")
    private static let cellID = NSUserInterfaceItemIdentifier("logCell")

    weak var table: NSTableView?
    private(set) var rows: [LogEntry] = []
    private var themeObserver: (any NSObjectProtocol)?
    private var rowHeight: CGFloat { ceil(14 * OMScale.ui) + 4 }

    isolated deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    /// 主题切换时整表重载(颜色取自令牌)。
    func observeTheme() {
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.table?.reloadData() }
        }
    }

    /// 应用新的行集合:纯尾部追加走增量插入,其余整表重载。
    func apply(rows newRows: [LogEntry], follow: Bool) {
        guard let table else { return }
        if newRows.count == rows.count, newRows.first?.id == rows.first?.id, newRows.last?.id == rows.last?.id {
            return
        }
        let isAppend = !rows.isEmpty && newRows.count > rows.count
            && newRows.first?.id == rows.first?.id && newRows[rows.count - 1].id == rows.last?.id
        let oldCount = rows.count
        rows = newRows
        if isAppend {
            table.insertRows(at: IndexSet(oldCount..<newRows.count), withAnimation: [])
        } else {
            table.reloadData()
        }
        if follow, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
    }

    // MARK: 数据源与代理

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = Self.cellID
            cell.lineBreakMode = .byTruncatingTail
            cell.maximumNumberOfLines = 1
            cell.cell?.truncatesLastVisibleLine = true
        }
        let entry = rows[row]
        cell.font = NSFont.monospacedSystemFont(ofSize: 11 * OMScale.ui, weight: .regular)
        cell.textColor = NSColor(Self.color(for: entry.level))
        cell.stringValue = entry.line
        cell.toolTip = entry.line
        return cell
    }

    /// 级别对应的令牌色。
    static func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return OMColors.tertiaryText
        case .info: return OMColors.primaryText
        case .warning: return OMColors.warning
        case .error: return OMColors.danger
        }
    }
}
