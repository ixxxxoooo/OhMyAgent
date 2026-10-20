// @author ixxxxoooo
// Files 工作区导航栈测试。

import Testing
@testable import WorkbenchKit

@Suite("Files 导航栈")
struct FilesNavStackTests {
    @Test("空栈无法前进后退,压入后指向最新项")
    func pushAndCurrent() {
        var stack = FilesNavStack()
        #expect(stack.current == nil)
        #expect(!stack.canGoBack && !stack.canGoForward)
        stack.push("/a")
        stack.push("/b")
        #expect(stack.current == "/b")
        #expect(stack.canGoBack && !stack.canGoForward)
    }

    @Test("相邻重复与空路径被忽略")
    func dedupe() {
        var stack = FilesNavStack()
        stack.push("/a")
        stack.push("/a")
        stack.push("")
        #expect(stack.entries == ["/a"])
    }

    @Test("后退再前进回到原位;从中间导航会截断前进记录")
    func backForwardTruncate() {
        var stack = FilesNavStack()
        ["/a", "/b", "/c"].forEach { stack.push($0) }
        #expect(stack.back() == "/b")
        #expect(stack.back() == "/a")
        #expect(stack.back() == nil)
        #expect(stack.forward() == "/b")
        stack.push("/d")
        #expect(stack.entries == ["/a", "/b", "/d"])
        #expect(!stack.canGoForward)
    }

    @Test("超过上限时裁剪最旧记录")
    func limit() {
        var stack = FilesNavStack()
        for index in 0..<(FilesNavStack.limit + 10) { stack.push("/f\(index)") }
        #expect(stack.entries.count == FilesNavStack.limit)
        #expect(stack.current == "/f\(FilesNavStack.limit + 9)")
        #expect(stack.entries.first == "/f10")
    }

    @Test("删除当前项后回退到前驱;删除历史项后游标平移")
    func removeKeepsCursor() {
        var stack = FilesNavStack()
        ["/a", "/b", "/c"].forEach { stack.push($0) }
        stack.remove { $0 == "/c" }
        #expect(stack.current == "/b")
        stack.remove { $0 == "/a" }
        #expect(stack.entries == ["/b"])
        #expect(stack.current == "/b")
        stack.remove { _ in true }
        #expect(stack.current == nil)
        #expect(stack.cursor == -1)
    }

    @Test("按目录前缀批量移除后相邻重复合并")
    func removeMergesDuplicates() {
        var stack = FilesNavStack()
        ["/x", "/dir/1", "/x", "/dir/2", "/y"].forEach { stack.push($0) }
        stack.remove { $0.hasPrefix("/dir/") }
        #expect(stack.entries == ["/x", "/y"])
        #expect(stack.current == "/y")
    }
}
