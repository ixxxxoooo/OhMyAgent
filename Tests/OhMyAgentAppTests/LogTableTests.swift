// @author ixxxxoooo
// 日志表格测试:增量追加、整表替换与行高。

import AppKit
import Foundation
import OMLog
import Testing
@testable import OhMyAgentApp

@MainActor
struct LogTableTests {
    private func entry(_ id: UInt64, _ level: LogLevel = .info) -> LogEntry {
        LogEntry(id: id, date: Date(timeIntervalSince1970: 0), level: level, category: .app, message: "m\(id)", fields: [:], process: "app")
    }

    private func makeCoordinator() -> (LogTableCoordinator, NSTableView) {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: LogTableCoordinator.columnID))
        let coordinator = LogTableCoordinator()
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        return (coordinator, table)
    }

    @Test("纯尾部追加保持原有行,整体替换则重载")
    func appendAndReplace() {
        let (coordinator, table) = makeCoordinator()
        coordinator.apply(rows: [entry(1), entry(2)], follow: false)
        #expect(table.numberOfRows == 2)
        coordinator.apply(rows: [entry(1), entry(2), entry(3)], follow: true)
        #expect(table.numberOfRows == 3)
        #expect(coordinator.rows.map(\.id) == [1, 2, 3])
        coordinator.apply(rows: [entry(5)], follow: false)
        #expect(table.numberOfRows == 1)
        coordinator.apply(rows: [], follow: false)
        #expect(table.numberOfRows == 0)
    }

    @Test("行内容相同时不做任何更新")
    func unchangedIsNoop() {
        let (coordinator, table) = makeCoordinator()
        let rows = [entry(1), entry(2)]
        coordinator.apply(rows: rows, follow: false)
        coordinator.apply(rows: rows, follow: false)
        #expect(table.numberOfRows == 2)
    }
}
