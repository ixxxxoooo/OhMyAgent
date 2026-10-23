// @author ixxxxoooo
// 行级编辑命令、文本搜索、Snippet 与 Emmet 的单元测试。

import Foundation
import Testing
@testable import EditorCore

/// 把命令产出应用到文本上(按升序编辑从后向前替换),返回新文本。
private func applied(_ text: String, _ outcome: EditOutcome?) -> String {
    guard let outcome else { return text }
    let ns = NSMutableString(string: text)
    for edit in outcome.edits.reversed() { ns.replaceCharacters(in: edit.range.nsRange, with: edit.text) }
    return ns as String
}

private func caret(_ offset: Int) -> [Selection] { [Selection(caret: offset)] }

@Suite("行级编辑命令")
struct LineOperationsTests {
    @Test("上移行:与上一行交换,光标随行移动")
    func moveUp() {
        let rope = TextRope("a\nb\nc")
        let outcome = LineOperations.moveLines(rope: rope, selections: caret(2), up: true)
        #expect(applied("a\nb\nc", outcome) == "b\na\nc")
        #expect(outcome?.selections == [Selection(caret: 0)])
    }

    @Test("首行上移无变化")
    func moveUpAtTop() {
        #expect(LineOperations.moveLines(rope: TextRope("a\nb"), selections: caret(0), up: true) == nil)
    }

    @Test("下移多行块")
    func moveDownBlock() {
        let text = "a\nb\nc\nd"
        let result = LineOperations.moveLines(rope: TextRope(text), selections: [Selection(anchor: 0, head: 3)], up: false)
        #expect(applied(text, result) == "c\na\nb\nd")
        #expect(result?.selections == [Selection(anchor: 2, head: 5)])
    }

    @Test("向下复制:选区落在副本上")
    func duplicateDown() {
        let text = "ab\ncd"
        let outcome = LineOperations.duplicateLines(rope: TextRope(text), selections: caret(1), down: true)
        #expect(applied(text, outcome) == "ab\nab\ncd")
        #expect(outcome.selections == [Selection(caret: 4)])
    }

    @Test("向上复制:选区留在上方副本")
    func duplicateUp() {
        let text = "ab\ncd"
        let outcome = LineOperations.duplicateLines(rope: TextRope(text), selections: caret(4), down: false)
        #expect(applied(text, outcome) == "ab\ncd\ncd")
        #expect(outcome.selections == [Selection(caret: 4)])
    }

    @Test("删除行:含末行")
    func deleteLines() {
        let rope = TextRope("a\nb\nc")
        #expect(applied("a\nb\nc", LineOperations.deleteLines(rope: rope, selections: caret(2))) == "a\nc")
        #expect(applied("a\nb\nc", LineOperations.deleteLines(rope: rope, selections: caret(4))) == "a\nb")
        #expect(applied("a", LineOperations.deleteLines(rope: TextRope("a"), selections: caret(0))) == "")
    }

    @Test("合并行:折叠前导空白为一个空格")
    func joinLines() {
        let text = "foo\n    bar\nbaz"
        let outcome = LineOperations.joinLines(rope: TextRope(text), selections: caret(1))
        #expect(applied(text, outcome) == "foo bar\nbaz")
        #expect(outcome?.selections == [Selection(caret: 3)])
    }

    @Test("上下插入新行沿用缩进")
    func insertLine() {
        let text = "  if x {\n  }"
        let below = LineOperations.insertLine(rope: TextRope(text), selections: caret(3), below: true, indentUnit: "    ")
        #expect(applied(text, below) == "  if x {\n      \n  }")
        let above = LineOperations.insertLine(rope: TextRope(text), selections: caret(3), below: false, indentUnit: "    ")
        #expect(applied(text, above) == "  \n  if x {\n  }")
        #expect(above.selections == [Selection(caret: 2)])
    }

    @Test("切换行注释:加上再取消,取最小缩进列")
    func toggleComment() {
        let text = "  a\n    b\n\n  c"
        let all = [Selection(anchor: 0, head: text.utf16.count)]
        let commented = applied(text, LineOperations.toggleLineComment(rope: TextRope(text), selections: all, prefix: "//"))
        #expect(commented == "  // a\n  //   b\n\n  // c")
        let restored = applied(commented, LineOperations.toggleLineComment(rope: TextRope(commented), selections: [Selection(anchor: 0, head: commented.utf16.count)], prefix: "//"))
        #expect(restored == text)
    }

    @Test("块注释切换")
    func blockComment() {
        let text = "foo bar"
        let wrapped = applied(text, LineOperations.toggleBlockComment(rope: TextRope(text), selections: [Selection(anchor: 0, head: 3)], open: "/*", close: "*/"))
        #expect(wrapped == "/* foo */ bar")
        let unwrapped = applied(wrapped, LineOperations.toggleBlockComment(rope: TextRope(wrapped), selections: [Selection(anchor: 0, head: 9)], open: "/*", close: "*/"))
        #expect(unwrapped == text)
    }

    @Test("排序与大小写、去行尾空白")
    func sortAndCase() {
        #expect(applied("b\na\nc", LineOperations.sortLines(rope: TextRope("b\na\nc"), selections: caret(0), descending: false)) == "a\nb\nc")
        #expect(applied("b\na\nc", LineOperations.sortLines(rope: TextRope("b\na\nc"), selections: caret(0), descending: true)) == "c\nb\na")
        #expect(applied("hello world", LineOperations.transformCase(rope: TextRope("hello world"), selections: [Selection(anchor: 0, head: 5)], transform: .upper)) == "HELLO world")
        #expect(applied("hello world", LineOperations.transformCase(rope: TextRope("hello world"), selections: caret(8), transform: .upper)) == "hello WORLD")
        #expect(applied("a  \nb\t\nc", LineOperations.trimTrailingWhitespace(rope: TextRope("a  \nb\t\nc"), selections: caret(0))) == "a\nb\nc")
    }
}

@Suite("文本搜索")
struct TextSearchTests {
    @Test("字面、整词、大小写")
    func options() {
        let rope = TextRope("Foo foo foobar FOO")
        #expect(TextSearch.matches(in: rope, pattern: "foo").count == 4)
        #expect(TextSearch.matches(in: rope, pattern: "foo", options: SearchOptions(caseSensitive: true)).count == 2)
        #expect(TextSearch.matches(in: rope, pattern: "foo", options: SearchOptions(wholeWord: true)).count == 3)
    }

    @Test("正则与非法正则")
    func regex() {
        let rope = TextRope("a1 b22 c333")
        #expect(TextSearch.matches(in: rope, pattern: "\\d+", options: SearchOptions(regex: true)).map(\.length) == [1, 2, 3])
        #expect(TextSearch.matches(in: rope, pattern: "(", options: SearchOptions(regex: true)).isEmpty)
    }

    @Test("下一个/上一个与回绕")
    func nextAndPrevious() {
        let rope = TextRope("ab ab ab")
        #expect(TextSearch.next(in: rope, pattern: "ab", from: 1)?.location == 3)
        #expect(TextSearch.next(in: rope, pattern: "ab", from: 7)?.location == 0)
        #expect(TextSearch.next(in: rope, pattern: "ab", from: 7, wrap: false) == nil)
        #expect(TextSearch.next(in: rope, pattern: "ab", from: 5, backward: true)?.location == 3)
        #expect(TextSearch.next(in: rope, pattern: "ab", from: 0, backward: true)?.location == 6)
    }

    @Test("大文件跨窗口也能找全")
    func largeDocument() {
        let line = String(repeating: "x", count: 99) + "\n"
        let text = String(repeating: line, count: 20_000) + "needle"
        let rope = TextRope(text)
        #expect(TextSearch.matches(in: rope, pattern: "needle").count == 1)
        #expect(TextSearch.matches(in: rope, pattern: "xx", options: SearchOptions(), limit: 10).count == 10)
    }
}

@Suite("Snippet")
struct SnippetTests {
    @Test("占位、默认值与最终光标")
    func basic() {
        let parsed = SnippetParser.parse("func ${1:name}(${2:arg}) {\n\t$0\n}")
        #expect(parsed.text == "func name(arg) {\n\t\n}")
        #expect(parsed.stops.map(\.index) == [1, 2, 0])
        #expect(parsed.stops[0].ranges == [TextSpan(location: 5, length: 4)])
    }

    @Test("镜像占位使用首个非空默认值")
    func mirror() {
        let parsed = SnippetParser.parse("${1:x} = $1;")
        #expect(parsed.text == "x = x;")
        #expect(parsed.stops[0].ranges.count == 2)
    }

    @Test("选项与变量、转义")
    func choiceAndVariables() {
        let parsed = SnippetParser.parse("${1|a,b|} $TM_FILENAME \\$1 ${UNKNOWN:fallback}", variables: ["TM_FILENAME": "x.swift"])
        #expect(parsed.text == "a x.swift $1 fallback")
        #expect(parsed.stops[0].choices == ["a", "b"])
    }

    @Test("无 $0 时最终光标落在文末")
    func implicitFinal() {
        let parsed = SnippetParser.parse("hi $1!")
        #expect(parsed.stops.last?.index == 0)
        #expect(parsed.stops.last?.ranges == [TextSpan(location: 4, length: 0)])
    }

    @Test("会话经编辑映射后占位随之增长")
    func sessionMapping() {
        let parsed = SnippetParser.parse("[${1:abc}]$0")
        var session = SnippetSession(snippet: parsed, origin: 10)
        #expect(session.currentStop.ranges == [TextSpan(location: 11, length: 3)])
        // 在占位中间输入两个字符。
        session.map(through: [AppliedEdit(location: 12, oldLength: 0, newLength: 2, startLine: 0, removedLines: 0, insertedLines: 0)])
        #expect(session.currentStop.ranges == [TextSpan(location: 11, length: 5)])
        let first = session.advance()
        #expect(first)
        #expect(session.isAtFinalStop)
        let second = session.advance()
        #expect(!second)
    }
}

@Suite("Emmet")
struct EmmetTests {
    @Test("基本标签、类、编号与乘法")
    func html() {
        #expect(Emmet.expand("div.box#main", syntax: .html) == "<div id=\"main\" class=\"box\">$1</div>$0")
        #expect(Emmet.expand("ul>li.item$*2", syntax: .html, indentUnit: "  ") ==
                "<ul>\n  <li class=\"item1\">$1</li>\n  <li class=\"item2\">$2</li>\n</ul>$0")
        #expect(Emmet.expand("p{hi}", syntax: .html) == "<p>hi</p>$0")
    }

    @Test("兄弟、爬升与分组")
    func structure() {
        #expect(Emmet.expand("a+b", syntax: .html) == "<a href=\"$1\">$2</a>\n<b>$3</b>$0")
        let nested = Emmet.expand("div>p>span^^h1", syntax: .html, indentUnit: " ")
        #expect(nested == "<div>\n <p>\n  <span>$1</span>\n </p>\n</div>\n<h1>$2</h1>$0")
        #expect(Emmet.expand("(a+b)*2", syntax: .html)?.components(separatedBy: "<a").count == 3)
    }

    @Test("隐式标签、自闭合与属性")
    func implicit() {
        #expect(Emmet.expand("ul>.x", syntax: .html, indentUnit: " ") == "<ul>\n <li class=\"x\">$1</li>\n</ul>$0")
        #expect(Emmet.expand("img", syntax: .html) == "<img src=\"$1\" alt=\"$2\">$0")
        #expect(Emmet.expand("img", syntax: .jsx) == "<img src=\"$1\" alt=\"$2\" />$0")
        #expect(Emmet.expand("a[href=x title=\"y z\"]", syntax: .html) == "<a href=\"x\" title=\"y z\">$1</a>$0")
    }

    @Test("非法缩写返回 nil;提取缩写")
    func invalidAndExtract() {
        #expect(Emmet.expand("div>", syntax: .html) != nil)
        #expect(Emmet.expand("(div", syntax: .html) == nil)
        let found = Emmet.abbreviation(in: "    ul>li*3", syntax: .html)
        #expect(found?.text == "ul>li*3")
        #expect(found?.start == 4)
        #expect(Emmet.abbreviation(in: "a{hello world}", syntax: .html)?.text == "a{hello world}")
    }

    @Test("CSS 缩写")
    func css() {
        #expect(Emmet.expand("m10", syntax: .css) == "margin: 10px;$0")
        #expect(Emmet.expand("p10-20", syntax: .css) == "padding: 10px 20px;$0")
        #expect(Emmet.expand("w50p", syntax: .css) == "width: 50%;$0")
        #expect(Emmet.expand("df", syntax: .css) == "display: flex;$0")
        #expect(Emmet.expand("z10", syntax: .css) == "z-index: 10;$0")
        #expect(Emmet.expand("c#f00", syntax: .css) == "color: #f00;$0")
        #expect(Emmet.expand("m-10", syntax: .css) == "margin: -10px;$0")
        #expect(Emmet.expand("zzzz", syntax: .css) == nil)
    }
}
