// @author ixxxxoooo
// 编辑器查找逻辑测试。

import Foundation
import Testing
@testable import EditorKit

@Suite("EditorFindEngine")
struct EditorFindTests {
    private func ranges(_ query: String, in text: String, _ options: EditorFindOptions = .init()) -> [NSRange] {
        guard let regex = EditorFindEngine.compile(query: query, options: options) else { return [] }
        return EditorFindEngine.matches(of: regex, in: text).map(\.range)
    }

    @Test("默认忽略大小写,且把查询当作普通文本")
    func plainCaseInsensitive() {
        #expect(ranges("a.b", in: "A.B a.b axb") == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
    }

    @Test("区分大小写")
    func caseSensitive() {
        #expect(ranges("Foo", in: "Foo foo", .init(caseSensitive: true)) == [NSRange(location: 0, length: 3)])
    }

    @Test("全词匹配")
    func wholeWord() {
        #expect(ranges("cat", in: "cat concat cat.", .init(wholeWord: true)).count == 2)
    }

    @Test("正则与非法正则")
    func regex() {
        #expect(ranges("\\d+", in: "a12 b345", .init(regex: true)).count == 2)
        #expect(EditorFindEngine.compile(query: "(", options: .init(regex: true)) == nil)
        #expect(EditorFindEngine.compile(query: "", options: .init()) == nil)
    }

    @Test("前后跳转会回绕")
    func stepping() {
        let list = [NSRange(location: 2, length: 1), NSRange(location: 8, length: 1)]
        #expect(EditorFindEngine.index(in: list, from: 3, forward: true) == 1)
        #expect(EditorFindEngine.index(in: list, from: 9, forward: true) == 0)
        #expect(EditorFindEngine.index(in: list, from: 8, forward: false) == 0)
        #expect(EditorFindEngine.index(in: list, from: 2, forward: false) == 1)
        #expect(EditorFindEngine.index(in: [], from: 0, forward: true) == nil)
    }

    @Test("正则替换支持捕获组")
    func replacementTemplate() throws {
        let options = EditorFindOptions(regex: true)
        let regex = try #require(EditorFindEngine.compile(query: "(\\w+)@", options: options))
        let result = try #require(EditorFindEngine.matches(of: regex, in: "bob@x").first)
        #expect(EditorFindEngine.replacement(for: result, regex: regex, in: "bob@x", template: "$1#", options: options) == "bob#")
        #expect(EditorFindEngine.replacement(for: result, regex: regex, in: "bob@x", template: "$1#", options: .init()) == "$1#")
    }
}
