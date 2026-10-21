// @author ixxxxoooo
// 全局替换纯逻辑测试:字面量、大小写、全词、正则捕获组、单行替换、非法正则。

import Testing
@testable import WorkbenchKit

@Suite("全局替换")
struct SearchReplaceTests {
    @Test("字面量替换所有匹配,不区分大小写")
    func literalCaseInsensitive() {
        let result = SearchReplace.replaceAll(in: "Foo foo FOO", options: SearchOptions(query: "foo"), replacement: "bar")
        #expect(result == ReplaceResult(text: "bar bar bar", count: 3))
    }

    @Test("区分大小写时只替换同大小写")
    func caseSensitive() {
        let result = SearchReplace.replaceAll(in: "Foo foo", options: SearchOptions(query: "foo", caseSensitive: true), replacement: "x")
        #expect(result == ReplaceResult(text: "Foo x", count: 1))
    }

    @Test("全词匹配不替换更长单词的一部分")
    func wholeWord() {
        let result = SearchReplace.replaceAll(in: "cat concat cat.", options: SearchOptions(query: "cat", wholeWord: true), replacement: "dog")
        #expect(result == ReplaceResult(text: "dog concat dog.", count: 2))
    }

    @Test("非正则模式下特殊字符按字面量处理,替换中的 $ 不被解释")
    func literalSpecials() {
        let result = SearchReplace.replaceAll(in: "a.b a.b", options: SearchOptions(query: "a.b"), replacement: "$1")
        #expect(result == ReplaceResult(text: "$1 $1", count: 2))
    }

    @Test("正则模式支持捕获组引用")
    func regexGroups() {
        let result = SearchReplace.replaceAll(in: "key=1\nname=2", options: SearchOptions(query: "(\\w+)=(\\d)", isRegex: true), replacement: "$2:$1")
        #expect(result == ReplaceResult(text: "1:key\n2:name", count: 2))
    }

    @Test("行首行尾锚点按行匹配")
    func anchorsMatchLines() {
        let result = SearchReplace.replaceAll(in: "a\nb\nc", options: SearchOptions(query: "^", isRegex: true), replacement: "- ")
        #expect(result.text == "- a\n- b\n- c")
    }

    @Test("只替换指定行")
    func singleLine() {
        let result = SearchReplace.replace(inLine: 2, of: "x\nx\nx", options: SearchOptions(query: "x"), replacement: "y")
        #expect(result == ReplaceResult(text: "x\ny\nx", count: 1))
        #expect(SearchReplace.replace(inLine: 9, of: "x", options: SearchOptions(query: "x"), replacement: "y").count == 0)
    }

    @Test("非法正则与空查询不改动文本")
    func invalidInput() {
        #expect(SearchReplace.replaceAll(in: "abc", options: SearchOptions(query: "(", isRegex: true), replacement: "x").count == 0)
        #expect(SearchReplace.replaceAll(in: "abc", options: SearchOptions(query: ""), replacement: "x").text == "abc")
    }

    @Test("没有匹配时次数为 0 且文本不变")
    func noMatch() {
        #expect(SearchReplace.replaceAll(in: "abc", options: SearchOptions(query: "z"), replacement: "x") == ReplaceResult(text: "abc", count: 0))
    }
}
