// @author ixxxxoooo
// Files 工作区状态(当前文件、导航、标签到文件的映射)测试。

import Foundation
import Testing
import WorkbenchKit
@testable import OhMyAgentApp

@MainActor
@Suite("Files 工作区状态")
struct FilesWorkspaceTests {
    @Test("打开文件后可后退/前进;被删除的目录会清掉其下记录")
    func openBackForgetPrune() {
        let model = FilesWorkspaceModel()
        model.open("/p/a.swift")
        model.open("/p/dir/b.swift")
        model.open("/p/c.swift")
        #expect(model.current == "/p/c.swift")
        model.back()
        #expect(model.current == "/p/dir/b.swift")
        model.forward()
        #expect(model.current == "/p/c.swift")
        model.forget("/p/dir")
        #expect(model.nav.entries == ["/p/a.swift", "/p/c.swift"])
    }

    @Test("Files 标签映射到工作区当前文件,文件标签映射到自己的路径,其他标签没有文件")
    func filePathOfTab() {
        let store = FilesWorkspaceStore()
        store.model(for: "/p").open("/p/x.md")
        let files = WorkbenchTab(kind: .preview(id: WorkbenchModel.toolsTabPrefix + "files"), title: "文件")
        let search = WorkbenchTab(kind: .preview(id: WorkbenchModel.toolsTabPrefix + "search"), title: "搜索")
        let file = WorkbenchTab(kind: .file(path: "/p/y.md"), title: "y.md")
        #expect(store.filePath(of: files, project: "/p") == "/p/x.md")
        #expect(store.filePath(of: files, project: "/other") == nil)
        #expect(store.filePath(of: files, project: nil) == nil)
        #expect(store.filePath(of: search, project: "/p") == nil)
        #expect(store.filePath(of: file, project: nil) == "/p/y.md")
        store.forget("/p/x.md")
        #expect(store.filePath(of: files, project: "/p") == nil)
    }
}
