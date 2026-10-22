// @author ixxxxoooo
// 语法高亮:语言识别(扩展名/围栏别名)、新增语言的词法片段、带色文本与缓存。

import EditorKit
import Foundation
import SwiftUI
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("代码高亮")
struct CodeHighlighterTests {
    @Test("扩展名与文件名识别")
    func detectLanguages() {
        #expect(SyntaxLanguage.detect(path: "/a/.cursor/rules/swift.mdc") == .markdown)
        #expect(FilePreviewKind.of(path: "/a/.cursor/rules/swift.mdc") == .markdown)
        #expect(SyntaxLanguage.detect(path: "/a/index.html") == .html)
        #expect(SyntaxLanguage.detect(path: "/a/icon.svg") == .html)
        #expect(SyntaxLanguage.detect(path: "/a/site.scss") == .css)
        #expect(SyntaxLanguage.detect(path: "/a/q.sql") == .sql)
        #expect(SyntaxLanguage.detect(path: "/a/Dockerfile") == .dockerfile)
        #expect(SyntaxLanguage.detect(path: "/a/Gemfile.rb") == .ruby)
        #expect(SyntaxLanguage.detect(path: "/a/Cargo.toml") == .toml)
        #expect(SyntaxLanguage.detect(path: "/a/x.unknown") == .plain)
    }

    @Test("围栏别名")
    func fenceAliases() {
        #expect(SyntaxLanguage.fromFence("ts") == .typescript)
        #expect(SyntaxLanguage.fromFence("sh") == .shell)
        #expect(SyntaxLanguage.fromFence("yml") == .yaml)
        #expect(SyntaxLanguage.fromFence("swift title=\"a\"") == .swift)
        #expect(SyntaxLanguage.fromFence("  C++ ") == .c)
        #expect(SyntaxLanguage.fromFence(nil) == .plain)
        #expect(SyntaxLanguage.fromFence("nonsense") == .plain)
    }

    @Test("HTML:标签、属性、字符串、注释")
    func htmlSpans() {
        let text = "<!-- hi --><div class=\"a\">x &amp; y</div>"
        let spans = SimpleLexer.lex(text, language: .html)
        let kinds = spans.map(\.kind)
        #expect(kinds.contains(.comment))
        #expect(kinds.contains(.keyword))
        #expect(kinds.contains(.property))
        #expect(kinds.contains(.string))
        #expect(kinds.contains(.number))
        // 片段互不重叠且升序
        for (a, b) in zip(spans, spans.dropFirst()) { #expect(a.location + a.length <= b.location) }
    }

    @Test("CSS:选择器、属性、颜色、数值")
    func cssSpans() {
        let text = ".box { color: #fff; margin: 10px; } /* c */"
        let spans = SimpleLexer.lex(text, language: .css)
        func kind(of word: String) -> SyntaxKind? {
            guard let range = text.range(of: word) else { return nil }
            let loc = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
            return spans.first { $0.location == loc }?.kind
        }
        #expect(kind(of: ".box") == .type)
        #expect(kind(of: "color") == .property)
        #expect(kind(of: "#fff") == .number)
        #expect(kind(of: "10px") == .number)
        #expect(kind(of: "/* c */") == .comment)
    }

    @Test("SQL:关键字忽略大小写,-- 注释")
    func sqlSpans() {
        let text = "SELECT id FROM t -- note\nwhere x = 'a'"
        let spans = SimpleLexer.lex(text, language: .sql)
        let keywordCount = spans.filter { $0.kind == .keyword }.count
        #expect(keywordCount == 3) // SELECT FROM where
        #expect(spans.contains { $0.kind == .comment })
        #expect(spans.contains { $0.kind == .string })
    }

    @Test("带色文本保留原文并产生多种前景色")
    func attributedKeepsText() {
        let code = "let x = 42 // answer\nfunc f() {}"
        let result = CodeHighlighter.attributed(code, language: .swift)
        #expect(String(result.characters) == code)
        var colors = 0
        for run in result.runs where run.foregroundColor != nil { colors += 1 }
        #expect(colors >= 4)
        // 缓存命中返回同样内容
        #expect(CodeHighlighter.attributed(code, language: .swift) == result)
    }

    @Test("纯文本与超长文本不上色")
    func plainAndHuge() {
        let plain = CodeHighlighter.attributed("hello", language: .plain)
        #expect(plain.runs.allSatisfy { $0.foregroundColor == nil })
        let huge = String(repeating: "let a = 1\n", count: CodeHighlighter.maxCharacters / 5)
        let result = CodeHighlighter.attributed(huge, language: .swift)
        #expect(result.runs.allSatisfy { $0.foregroundColor == nil })
    }
}
