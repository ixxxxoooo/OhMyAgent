// @author ixxxxoooo
// 文件面包屑:相对路径计算。

import Foundation
import Testing

@testable import OhMyAgentApp

@Suite("文件面包屑")
struct FileBreadcrumbTests {
    @Test("项目内取相对路径,兼容根目录带尾部斜杠")
    func relative() {
        #expect(FileBreadcrumb.relativePath("/p/a/b/c.md", root: "/p") == "a/b/c.md")
        #expect(FileBreadcrumb.relativePath("/p/a/b/c.md", root: "/p/") == "a/b/c.md")
    }

    @Test("名称前缀相同的兄弟目录不会被误判为项目内")
    func siblingPrefix() {
        #expect(FileBreadcrumb.relativePath("/proj2/a.md", root: "/proj") == "/proj2/a.md")
    }

    @Test("项目外的文件回退为绝对路径(主目录缩写为 ~)")
    func outside() {
        let home = NSHomeDirectory()
        #expect(FileBreadcrumb.relativePath(home + "/notes/a.md", root: "/elsewhere") == "~/notes/a.md")
    }
}

@Suite("面包屑分段")
struct FileBreadcrumbSegmentTests {
    @Test("项目内从根的下一级逐级拆分,末段为文件")
    func inside() {
        let parts = FileBreadcrumb.segments(path: "/p/a/b/c.md", root: "/p")
        #expect(parts.map(\.name) == ["a", "b", "c.md"])
        #expect(parts.map(\.path) == ["/p/a", "/p/a/b", "/p/a/b/c.md"])
        #expect(parts[0].parentDirectory == "/p")
        #expect(parts[2].parentDirectory == "/p/a/b")
    }

    @Test("项目外从根开始;同名前缀目录不误判")
    func outside() {
        let parts = FileBreadcrumb.segments(path: "/proj2/a.md", root: "/proj")
        #expect(parts.map(\.name) == ["proj2", "a.md"])
        #expect(parts[0].parentDirectory == "/")
    }
}
