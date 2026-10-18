// @author ixxxxoooo
// 面板内顺序(工具栏图标、底部标签)的拖拽换序与容错解码。

import Foundation
import Testing
@testable import WorkbenchKit

struct PaneOrderTests {
    @Test func moveOntoTargetTakesItsPosition() {
        #expect(PaneOrder.moved([1, 2, 3], item: 3, onto: 1) == [3, 1, 2])
        #expect(PaneOrder.moved([1, 2, 3], item: 1, onto: 3) == [2, 3, 1])
        #expect(PaneOrder.moved([1, 2, 3], item: 1, onto: nil) == [2, 3, 1])
        #expect(PaneOrder.moved([1, 2, 3], item: 2, onto: 2) == [1, 2, 3])
    }

    @Test func normalizedFillsMissingAndDropsDuplicates() {
        #expect(PaneOrder.normalized([3, 3, 9], all: [1, 2, 3]) == [3, 1, 2])
        #expect(PaneOrder.normalized([], all: [1, 2]) == [1, 2])
    }

    @Test func layoutOrderRoundTripsAndOldFilesDefault() throws {
        var layout = WorkbenchLayout()
        layout.rightPaneOrder = [.git, .files, .search]
        layout.bottomPaneOrder = [.output, .terminal]
        let decoded = try JSONDecoder().decode(WorkbenchLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded.rightPaneOrder == [.git, .files, .search])
        #expect(decoded.bottomPaneOrder == [.output, .terminal])
        let old = try JSONDecoder().decode(WorkbenchLayout.self, from: Data("{}".utf8))
        #expect(old.rightPaneOrder == RightPane.available)
    }
}
