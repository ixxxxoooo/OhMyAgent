// @author ixxxxoooo
// IDE 窗口里的 Composer 多文件审阅标签:打开、复用、空项目忽略。

import Foundation
@testable import IDEKit
import Testing
import WorkbenchKit

@MainActor
@Suite("IDE Composer 审阅标签")
struct IDEComposerTabTests {
    private func makeModel() -> IDEWindowModel {
        IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: "/tmp/composer"))
    }

    @Test("打开审阅标签,重复打开聚焦同一个")
    func openAndReuse() {
        let model = makeModel()
        let first = model.openChanges(projectID: "/tmp/composer", title: "审阅")
        let second = model.openChanges(projectID: "/tmp/composer", title: "审阅")
        #expect(first != nil)
        #expect(first == second)
        #expect(model.editor.allTabs.filter { if case .changes = $0.kind { true } else { false } }.count == 1)
    }

    @Test("空项目标识被忽略")
    func emptyProject() {
        let model = makeModel()
        #expect(model.openChanges(projectID: "", title: "审阅") == nil)
        #expect(model.editor.allTabs.isEmpty)
    }
}
