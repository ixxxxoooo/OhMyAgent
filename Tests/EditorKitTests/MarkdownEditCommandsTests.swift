// @author ixxxxoooo
// Markdown 所见即所得的基础交互:任务框切换、链接目标、列表续行。

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

    @Test("点击未勾选任务框 → 勾选;再点 → 取消")
    func toggleTask() throws {
        let text = "- [ ] 买牛奶\n- [x] 写代码\n"
        let first = try #require(MarkdownEditCommands.toggleTask(in: text, at: 3))
        #expect(apply(first, to: text) == "- [x] 买牛奶\n- [x] 写代码\n")
        let second = try #require(MarkdownEditCommands.toggleTask(in: text, at: (text as NSString).range(of: "[x]").location + 1))
        #expect(apply(second, to: text) == "- [ ] 买牛奶\n- [ ] 写代码\n")
    }

    @Test("点在正文上不切换;非任务列表项不切换")
    func toggleTaskMisses() {
        let text = "- [ ] 买牛奶\n- 普通项\n"
        #expect(MarkdownEditCommands.toggleTask(in: text, at: 9) == nil)
        #expect(MarkdownEditCommands.toggleTask(in: text, at: (text as NSString).range(of: "普通").location) == nil)
        #expect(MarkdownEditCommands.toggleTask(in: text, at: 9999) == nil)
    }

    @Test("围栏代码里的 - [ ] 不是任务框(提供块布局时)")
    func toggleTaskIgnoresCodeFence() {
        let text = "```\n- [ ] 不是任务\n```\n"
        let layout = MarkdownLiveRenderer.layout(for: text)
        #expect(MarkdownEditCommands.toggleTask(in: text, at: 7, layout: layout) == nil)
    }

    @Test("有序列表与缩进的任务框也能切换")
    func toggleTaskVariants() throws {
        let text = "1. [ ] 一\n   - [X] 二\n"
        let edit = try #require(MarkdownEditCommands.toggleTask(in: text, at: 4))
        #expect(apply(edit, to: text) == "1. [x] 一\n   - [X] 二\n")
        let nested = try #require(MarkdownEditCommands.toggleTask(in: text, at: (text as NSString).range(of: "[X]").location))
        #expect(apply(nested, to: text) == "1. [ ] 一\n   - [ ] 二\n")
    }

    // MARK: 链接

    @Test("取链接目标:文字与目标范围内都命中,带标题的链接也行")
    func linkTarget() {
        let text = "看 [官网](https://example.com \"标题\") 与 [邮件](mailto:a@b.c)。"
        let ns = text as NSString
        #expect(MarkdownEditCommands.linkTarget(in: text, at: ns.range(of: "官网").location) == "https://example.com")
        #expect(MarkdownEditCommands.linkTarget(in: text, at: ns.range(of: "example").location) == "https://example.com")
        #expect(MarkdownEditCommands.linkTarget(in: text, at: ns.range(of: "邮件").location) == "mailto:a@b.c")
        #expect(MarkdownEditCommands.linkTarget(in: text, at: 0) == nil)
    }

    // MARK: 列表续行

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
