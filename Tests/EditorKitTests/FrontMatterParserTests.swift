// @author ixxxxoooo
// 前置元数据解析测试:键值、布尔、列表、引号,以及复杂 YAML 的回退。

import Testing
@testable import EditorKit

@Suite("前置元数据解析")
struct FrontMatterParserTests {
    @Test("Cursor 规则文件:文本、布尔、逗号分隔 globs")
    func cursorRule() {
        let source = """
        ---
        description: OhMyAgent 的 Swift 最佳实践(始终生效)
        globs: *.swift, Package.swift
        alwaysApply: true
        ---

        """
        let fields = FrontMatterParser.parse(source)
        #expect(fields == [
            FrontMatterField(key: "description", value: .text("OhMyAgent 的 Swift 最佳实践(始终生效)")),
            FrontMatterField(key: "globs", value: .list(["*.swift", "Package.swift"])),
            FrontMatterField(key: "alwaysApply", value: .bool(true)),
        ])
    }

    @Test("行内列表、块列表、引号与注释")
    func listsAndQuotes() {
        let source = "---\n# 注释\ntags: [a, \"b c\"]\ntitle: 'Hi: there'\nitems:\n  - x\n  - y\nempty:\n---"
        let fields = FrontMatterParser.parse(source)
        #expect(fields == [
            FrontMatterField(key: "tags", value: .list(["a", "b c"])),
            FrontMatterField(key: "title", value: .text("Hi: there")),
            FrontMatterField(key: "items", value: .list(["x", "y"])),
            FrontMatterField(key: "empty", value: .text("")),
        ])
    }

    @Test("嵌套、多行标量与空块回退为 nil")
    func fallback() {
        #expect(FrontMatterParser.parse("---\nouter:\n  inner: 1\n---") == nil)
        #expect(FrontMatterParser.parse("---\ntext: |\n  多行\n---") == nil)
        #expect(FrontMatterParser.parse("---\n---") == nil)
        #expect(FrontMatterParser.parse("没有分隔线") == nil)
    }
}
