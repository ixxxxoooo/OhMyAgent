// @author ixxxxoooo
// 索引忽略规则的解析与匹配。

import Testing
@testable import ChatKit

@Suite("索引忽略规则")
struct IndexIgnoreTests {
    @Test("空规则与注释不忽略任何路径")
    func emptyRules() {
        let ignore = IndexIgnore(text: "\n# 注释\n   \n")
        #expect(ignore.isEmpty)
        #expect(!ignore.ignores(relativePath: "a/b.swift", isDirectory: false))
    }

    @Test("无斜杠的 glob 匹配任一路径分量")
    func nameGlob() {
        let ignore = IndexIgnore(text: "*.min.js\nfixtures")
        #expect(ignore.ignores(relativePath: "web/app.min.js", isDirectory: false))
        #expect(ignore.ignores(relativePath: "tests/fixtures/a.txt", isDirectory: false))
        #expect(!ignore.ignores(relativePath: "web/app.js", isDirectory: false))
    }

    @Test("结尾斜杠只匹配目录,含斜杠的 glob 按相对路径匹配")
    func directoryAndAnchored() {
        let ignore = IndexIgnore(text: "generated/\ndocs/api/*")
        #expect(ignore.ignores(relativePath: "src/generated", isDirectory: true))
        #expect(!ignore.ignores(relativePath: "src/generated", isDirectory: false))
        #expect(ignore.ignores(relativePath: "src/generated/x.swift", isDirectory: false))
        #expect(ignore.ignores(relativePath: "docs/api/index.md", isDirectory: false))
        #expect(!ignore.ignores(relativePath: "docs/guide.md", isDirectory: false))
    }
}
