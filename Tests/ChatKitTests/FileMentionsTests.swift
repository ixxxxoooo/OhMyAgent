// @author ixxxxoooo
// 文件提及解析测试:相对/绝对/带引号路径、不存在的路径与 @agent 提及被忽略、去重与移除。

import Foundation
import Testing
@testable import ChatKit

@Suite("文件提及")
struct FileMentionsTests {
    private let workspace = URL(fileURLWithPath: "/ws")

    /// 假文件系统:`/ws/a.swift` 文件,`/ws/Sources` 目录,`/ws/my docs/b.md` 文件。
    private func fake(_ path: String) -> Bool? {
        switch path {
        case "/ws/a.swift", "/ws/my docs/b.md", "/abs/x.txt": return false
        case "/ws/Sources": return true
        default: return nil
        }
    }

    @Test("解析相对、带引号与绝对路径,目录标记正确")
    func parsePaths() {
        let text = "看 @a.swift 和 @Sources/ 以及 @\"my docs/b.md\" 还有 @/abs/x.txt"
        let items = FileMentions.parse(text, workspace: workspace, exists: fake)
        #expect(items.map(\.name) == ["a.swift", "Sources", "b.md", "x.txt"])
        #expect(items.map(\.isDirectory) == [false, true, false, false])
    }

    @Test("不存在的路径、@agent 与邮箱样式不识别")
    func ignoresNonFiles() {
        let items = FileMentions.parse("@agent-reviewer @nothing.txt foo@a.swift", workspace: workspace, exists: fake)
        #expect(items.isEmpty)
    }

    @Test("同一路径重复出现只保留一个")
    func dedup() {
        let items = FileMentions.parse("@a.swift 再看 @a.swift", workspace: workspace, exists: fake)
        #expect(items.count == 1)
    }

    @Test("移除提及时一并去掉其后的空格")
    func removal() throws {
        let text = "请看 @a.swift 然后修改"
        let mention = try #require(FileMentions.parse(text, workspace: workspace, exists: fake).first)
        #expect(FileMentions.remove(mention, from: text) == "请看 然后修改")
    }
}
