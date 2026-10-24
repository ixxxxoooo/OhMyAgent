// @author ixxxxoooo
// Markdown 列表续行(回车自动续出下一项、空项结束列表)的纯函数测试。

import Foundation
import Testing

@testable import EditorKit

@Suite("Markdown 编辑命令")
struct MarkdownEditCommandsTests {
    /// 把替换应用到文本,便于断言最终结果。
    private func apply(_ edit: MarkdownEdit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    // MARK: 任务框

    @Test("无序列表:行尾回车续出同样的标记")
    func continueBullet() throws {
        let text = "- 第一项"
        let edit = try #require(MarkdownEditCommands.continueList(in: text, selection: NSRange(location: 5, length: 0)))
        #expect(apply(edit, to: text) == "- 第一项\n- ")
        #expect(edit.caret == (apply(edit, to: text) as NSString).length)
    }

    @Test("有序列表数字递增;任务项续出未勾选的任务框;缩进与引用前缀保留")
    func continueVariants() throws {
        let ordered = "9. 九"
        let a = try #require(MarkdownEditCommands.continueList(in: ordered, selection: NSRange(location: 4, length: 0)))
        #expect(apply(a, to: ordered) == "9. 九\n10. ")
        let task = "- [x] 已完成"
        let b = try #require(MarkdownEditCommands.continueList(in: task, selection: NSRange(location: (task as NSString).length, length: 0)))
        #expect(apply(b, to: task) == "- [x] 已完成\n- [ ] ")
        let nested = "> - 引用里的项"
        let c = try #require(MarkdownEditCommands.continueList(in: nested, selection: NSRange(location: (nested as NSString).length, length: 0)))
        #expect(apply(c, to: nested) == "> - 引用里的项\n> - ")
    }

    @Test("空项回车结束列表(删掉标记)")
    func emptyItemEndsList() throws {
        let text = "- 一\n- "
        let edit = try #require(MarkdownEditCommands.continueList(in: text, selection: NSRange(location: (text as NSString).length, length: 0)))
        #expect(apply(edit, to: text) == "- 一\n")
        #expect(edit.caret == 4)
    }

    @Test("行中间回车、有选区、普通段落都不接管")
    func notApplicable() {
        #expect(MarkdownEditCommands.continueList(in: "- 一二三", selection: NSRange(location: 3, length: 0)) == nil)
        #expect(MarkdownEditCommands.continueList(in: "- 一二三", selection: NSRange(location: 2, length: 2)) == nil)
        #expect(MarkdownEditCommands.continueList(in: "普通段落", selection: NSRange(location: 4, length: 0)) == nil)
    }
}
