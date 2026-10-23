// @author ixxxxoooo
// LSP 扩展能力的解码测试:语义标记、内嵌提示、工作区符号、带片段与替换区间的补全项。

import ACPKit
import Foundation
import Testing
@testable import LSPKit

@Suite("LSP 扩展能力解码")
struct LSPExtrasTests {
    @Test("语义标记相对编码还原为绝对位置")
    func semanticTokens() {
        // 第 0 行 4 列长 3 类型 0(class)修饰 0b1;同行再偏 5 列长 2 类型 1(function);下一行 2 列长 4 类型 0。
        let data = [0, 4, 3, 0, 1, 0, 5, 2, 1, 0, 1, 2, 4, 0, 0]
        let tokens = LSPDecode.semanticTokens(data: data, types: ["class", "function"], modifiers: ["declaration"])
        #expect(tokens.count == 3)
        #expect(tokens[0] == LSPSemanticToken(line: 0, character: 4, length: 3, type: "class", modifiers: ["declaration"]))
        #expect(tokens[1].character == 9 && tokens[1].type == "function")
        #expect(tokens[2].line == 1 && tokens[2].character == 2)
    }

    @Test("语义标记遇到越界类型下标会跳过")
    func semanticTokensOutOfRange() {
        let tokens = LSPDecode.semanticTokens(data: [0, 0, 3, 9, 0], types: ["class"], modifiers: [])
        #expect(tokens.isEmpty)
    }

    @Test("内嵌提示支持字符串与分段标签")
    func inlayHints() {
        let json: JSONValue = .array([
            ["position": ["line": 1, "character": 5], "label": ": Int", "kind": 1, "paddingLeft": false],
            ["position": ["line": 2, "character": 0], "label": .array([["value": "name"], ["value": ":"]]), "kind": 2, "paddingRight": true],
            ["position": ["line": 3, "character": 0], "label": ""],
        ])
        let hints = LSPDecode.inlayHints(json)
        #expect(hints.count == 2)
        #expect(hints[0].label == ": Int" && hints[0].kind == 1)
        #expect(hints[1].label == "name:" && hints[1].paddingRight)
    }

    @Test("补全项保留片段原文、替换区间与文档")
    func completionSnippet() {
        let json: JSONValue = .array([
            [
                "label": "forEach", "kind": 2, "insertTextFormat": 2,
                "textEdit": ["range": ["start": ["line": 0, "character": 3], "end": ["line": 0, "character": 5]], "newText": "forEach { ${1:item} in $0 }"],
                "documentation": ["kind": "markdown", "value": "遍历"], "filterText": "forEach",
            ],
            ["label": "plain", "insertText": "plain"],
        ])
        let items = LSPDecode.completions(json)
        #expect(items.count == 2)
        #expect(items[0].snippet == "forEach { ${1:item} in $0 }")
        #expect(items[0].insertText == "forEach { item in  }")
        #expect(items[0].replaceRange?.start.character == 3)
        #expect(items[0].documentation == "遍历")
        #expect(items[1].snippet == nil)
    }

    @Test("工作区符号解码")
    func workspaceSymbols() {
        let json: JSONValue = .array([
            ["name": "Foo", "kind": 5, "containerName": "Module",
             "location": ["uri": "file:///a.swift", "range": ["start": ["line": 3, "character": 0], "end": ["line": 3, "character": 3]]]],
            ["name": "bad"],
        ])
        let symbols = LSPDecode.workspaceSymbols(json)
        #expect(symbols.count == 1)
        #expect(symbols[0].location.range.start.line == 3 && symbols[0].containerName == "Module")
    }
}
