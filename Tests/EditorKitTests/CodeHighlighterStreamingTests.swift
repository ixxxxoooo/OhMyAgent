// @author ixxxxoooo
// 代码块流式高亮:按稳定行边界续扫的结果必须与全量扫描完全一致。

import Foundation
import Testing

@testable import EditorKit

@MainActor
@Suite("代码块流式高亮续扫", .serialized)
struct CodeHighlighterStreamingTests {
    /// 把文本按固定大小切片逐步追加,每一步都与全量构建比较。
    private func assertStreamingMatchesFull(_ code: String, language: SyntaxLanguage, step: Int) {
        CodeHighlighter.clearCache()
        CodeHighlighter.resetStreaming()
        var prefix = ""
        var scalars = code.unicodeScalars.makeIterator()
        var done = false
        while !done {
            var taken = 0
            while taken < step {
                guard let scalar = scalars.next() else { done = true; break }
                prefix.unicodeScalars.append(scalar)
                taken += 1
            }
            let streamed = CodeHighlighter.attributed(prefix, language: language)
            let full = CodeHighlighter.build(prefix, language: language)
            #expect(streamed == full, "语言 \(language) 前缀长度 \(prefix.utf16.count) 的增量结果与全量不一致")
        }
    }

    @Test("Swift:函数、字符串、行注释、块注释逐片追加")
    func swiftStreaming() {
        let code = """
        /// 说明
        func hello(name: String) -> String {
            let text = "hi \\(name)" // 行尾注释
            /* 多行
               块注释 */
            return text.uppercased()
        }

        let value = 42
        """
        assertStreamingMatchesFull(code, language: .swift, step: 3)
    }

    @Test("跨行片段(块注释、反引号字符串)未闭合时不提前固化边界")
    func multilineSpansDoNotFreezeEarly() {
        let code = "let a = 1\n/* 未闭合的块注释\n还在注释里\n仍然在注释里\n*/ let b = 2\n`模板\n字符串`\nlet c = 3\n"
        assertStreamingMatchesFull(code, language: .typescript, step: 2)
    }

    @Test("Shell、JSON、Python、Markdown 也与全量一致")
    func otherLanguages() {
        assertStreamingMatchesFull("# 注释\nls -la \"$HOME\" && echo done\nif [ -f x ]; then\n  cat x\nfi\n", language: .shell, step: 4)
        assertStreamingMatchesFull("{\n  \"a\": 1,\n  \"b\": [true, null, \"x\"]\n}\n", language: .json, step: 3)
        assertStreamingMatchesFull("def f(x):\n    # 注释\n    return x + 1\n\nprint(f(2))\n", language: .python, step: 5)
        assertStreamingMatchesFull("# 标题\n\n正文 `code`\n\n- 项一\n- 项二\n", language: .markdown, step: 3)
    }

    @Test("流式追加会命中续扫,并且 HTML/CSS 不走增量")
    func resumesAndExcludesMarkup() {
        CodeHighlighter.clearCache()
        CodeHighlighter.resetStreaming()
        var code = ""
        for index in 0..<40 {
            code += "let value\(index) = \(index) // 注释\n"
            _ = CodeHighlighter.attributed(code, language: .swift)
        }
        #expect(CodeHighlighter.incrementalBuilds > 20)
        let before = CodeHighlighter.incrementalBuilds
        var html = ""
        for index in 0..<10 {
            html += "<div class=\"a\(index)\">\n"
            _ = CodeHighlighter.attributed(html, language: .html)
        }
        #expect(CodeHighlighter.incrementalBuilds == before)
    }

    @Test("同时流式输出的两个同语言代码块互不串扰")
    func interleavedStreamsStayCorrect() {
        CodeHighlighter.clearCache()
        CodeHighlighter.resetStreaming()
        var first = ""
        var second = ""
        for index in 0..<15 {
            first += "let a\(index) = \(index)\n"
            second += "var b\(index) = \"s\(index)\"\n"
            #expect(CodeHighlighter.attributed(first, language: .swift) == CodeHighlighter.build(first, language: .swift))
            #expect(CodeHighlighter.attributed(second, language: .swift) == CodeHighlighter.build(second, language: .swift))
        }
    }

    @Test("增长中的文本不写缓存;结束后精确命中并晋升进缓存")
    func growingTextSkipsCacheThenPromotes() {
        CodeHighlighter.clearCache()
        CodeHighlighter.resetStreaming()
        let lines = (0..<30).map { "let value\($0) = \($0) // 注释" }
        var text = ""
        for line in lines {
            text += line + "\n"
            _ = CodeHighlighter.attributed(text, language: .swift)
        }
        let before = CodeHighlighter.cacheStats
        // 结束后再次取同一文本:来自流式状态(记为命中),且与全量一致
        let again = CodeHighlighter.attributed(text, language: .swift)
        #expect(again == CodeHighlighter.build(text, language: .swift))
        #expect(CodeHighlighter.cacheStats.hits == before.hits + 1)
        // 晋升之后走缓存命中
        _ = CodeHighlighter.attributed(text, language: .swift)
        #expect(CodeHighlighter.cacheStats.hits == before.hits + 2)
    }

    @Test("追加段:上一次稳定边界之后的着色与全量结果的对应部分一致")
    func streamingSegmentMatchesFullSuffix() {
        CodeHighlighter.clearCache()
        CodeHighlighter.resetStreaming()
        var text = ""
        var stable = 0
        for step in 0..<40 {
            text += "func f\(step)() { return \"s\(step)\" } // 尾注释\n"
            let full = CodeHighlighter.attributed(text, language: .swift)
            if step > 0, let segment = CodeHighlighter.streamingSegment(text, language: .swift, from: stable) {
                var head = AttributedString()
                let units = Array(text.utf16)
                // 用全量结果的前 stable 个 UTF-16 单元 + 追加段重组,应与全量完全相等
                let prefix = String(decoding: units[..<stable], as: UTF16.self)
                let index = full.characters.index(full.startIndex, offsetBy: prefix.count)
                head = AttributedString(full[full.startIndex..<index])
                head.append(segment.text)
                #expect(head == full, "第 \(step) 步重组结果与全量不一致")
            }
            stable = CodeHighlighter.stableUnits(text, language: .swift)
        }
        #expect(stable > 0)
    }
}
