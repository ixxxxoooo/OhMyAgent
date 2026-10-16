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
