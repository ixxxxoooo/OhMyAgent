// @author ixxxxoooo
// frontmatter 属性视图(Obsidian 风格 Properties)的解析与往返测试。

import Foundation
import Testing
@testable import ClaudeConfigKit

@Suite("Frontmatter 属性")
struct FrontmatterPropertiesTests {
    private let sample = """
    ---
    name: swift-style
    description: "代码风格: 严格并发"
    user-invocable: true
    allowed-tools: [Read, Bash]
    paths:
      - "**/*.swift"
      - Sources/**
    # 一行注释
    empty:
    ---
    # 正文
    内容
    """

    @Test("属性按出现顺序解析并识别文本、布尔与列表类型")
    func parsesKinds() {
        let props = MarkdownDocument(parsing: sample).properties
        #expect(props.map(\.key) == ["name", "description", "user-invocable", "allowed-tools", "paths", "empty"])
        #expect(props[0].kind == .text && props[0].text == "swift-style")
        #expect(props[1].text == "代码风格: 严格并发")
        #expect(props[2].kind == .bool && props[2].text == "true")
        #expect(props[3].kind == .list && props[3].items == ["Read", "Bash"])
        #expect(props[4].kind == .list && props[4].items == ["**/*.swift", "Sources/**"])
        #expect(props[5].kind == .text && props[5].text.isEmpty)
    }

    @Test("无改动时往返渲染与原文完全一致(含注释与块列表)")
    func roundTripUnchanged() {
        let doc = MarkdownDocument(parsing: sample)
        #expect(doc.render() == sample)
    }

    @Test("修改一个属性不影响其他属性、注释和正文")
    func editKeepsOthers() {
        var doc = MarkdownDocument(parsing: sample)
        doc.setBool("user-invocable", false)
        let out = doc.render()
        #expect(out.contains("# 一行注释"))
        #expect(out.contains("  - Sources/**"))
        #expect(out.hasSuffix("# 正文\n内容"))
        #expect(MarkdownDocument(parsing: out).bool("user-invocable") == false)
    }

    @Test("新增属性:非法或重复键被拒绝,合法键追加到末尾")
    func addProperty() {
        var doc = MarkdownDocument(parsing: sample)
        let duplicate = doc.addProperty(key: "name")
        let invalid = doc.addProperty(key: "bad key")
        let added = doc.addProperty(key: "model")
        #expect(!duplicate && !invalid && added)
        #expect(doc.keys.last == "model")
        var plain = MarkdownDocument(parsing: "# 只有正文")
        let plainAdded = plain.addProperty(key: "paths")
        #expect(plainAdded)
        #expect(plain.render() == "---\npaths:\n---\n# 只有正文")
    }

    @Test("重命名属性保留值与续行")
    func renameKey() {
        var doc = MarkdownDocument(parsing: sample)
        let renamed = doc.renameKey("paths", to: "globs")
        #expect(renamed)
        #expect(MarkdownDocument(parsing: doc.render()).list("globs") == ["**/*.swift", "Sources/**"])
        let clash = doc.renameKey("globs", to: "name")
        let missing = doc.renameKey("missing", to: "x")
        #expect(!clash && !missing)
    }
}
