// @author ixxxxoooo
// 标签内容判同:同一文件的不同路径写法不应重复打开。

import Foundation
import Testing
@testable import WorkbenchKit

@Suite("标签内容判同")
struct TabKindSameContentTests {
    /// 带 `..` 与符号链接的写法与原路径视为同一文件。
    @Test func fileAliasesAreSame() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oma-samecontent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        #expect(TabKind.file(path: file.path).sameContent(as: .file(path: dir.path + "/sub/../note.txt")))
        #expect(TabKind.file(path: file.path).sameContent(as: .file(path: link.path + "/note.txt")))
        #expect(!TabKind.file(path: file.path).sameContent(as: .diff(path: file.path)))
    }

    /// 布局按规范化路径找到已打开的标签。
    @Test func layoutFindsAlias() {
        var layout = DockLayout()
        _ = layout.open(.file(path: "/tmp/a/b.txt"), title: "b.txt")
        #expect(layout.tab(for: .file(path: "/tmp/a/../a/b.txt")) != nil)
    }
}
