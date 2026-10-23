// @author ixxxxoooo
// IDE 窗口文件导航历史(标题栏回退 / 前进)测试。

import Foundation
@testable import IDEKit
import Testing

@MainActor
@Suite("IDE 文件导航历史")
struct IDENavigationTests {
    /// 新建一个指向临时根目录的窗口模型。
    private func makeModel() -> IDEWindowModel {
        IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: "/tmp/nav"))
    }

    @Test("打开文件依次记录并可回退前进")
    func backAndForward() {
        let model = makeModel()
        #expect(!model.canGoBack && !model.canGoForward)
        model.openFile("/tmp/nav/a.swift", preview: false)
        model.openFile("/tmp/nav/b.swift", preview: false)
        #expect(model.canGoBack)
        model.goBack()
        #expect(model.activeFilePath == "/tmp/nav/a.swift")
        #expect(model.canGoForward && !model.canGoBack)
        model.goForward()
        #expect(model.activeFilePath == "/tmp/nav/b.swift")
    }

    @Test("预览标签被复用后仍能回退到上一个文件")
    func previewTabReuseKeepsHistory() {
        let model = makeModel()
        model.openFile("/tmp/nav/a.swift")
        model.openFile("/tmp/nav/b.swift")
        #expect(model.editor.allTabs.count == 1)
        model.goBack()
        #expect(model.activeFilePath == "/tmp/nav/a.swift")
    }

    @Test("回退后打开新文件会截断前进记录")
    func openAfterBackTruncatesForward() {
        let model = makeModel()
        model.openFile("/tmp/nav/a.swift", preview: false)
        model.openFile("/tmp/nav/b.swift", preview: false)
        model.goBack()
        model.openFile("/tmp/nav/c.swift", preview: false)
        #expect(!model.canGoForward)
        model.goBack()
        #expect(model.activeFilePath == "/tmp/nav/a.swift")
    }

    @Test("删除目录后清除其下的历史")
    func deletingDirectoryForgetsHistory() {
        let model = makeModel()
        model.openFile("/tmp/nav/a.swift", preview: false)
        model.openFile("/tmp/nav/dir/b.swift", preview: false)
        model.openFile("/tmp/nav/c.swift", preview: false)
        model.closeFileTabs(under: "/tmp/nav/dir")
        model.goBack()
        #expect(model.activeFilePath == "/tmp/nav/a.swift")
        #expect(!model.fileNav.entries.contains("/tmp/nav/dir/b.swift"))
    }
}
