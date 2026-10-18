// @author ixxxxoooo
// `@browser` 提及与开发服务器检测:匹配边界、提示块内容、补全项、历史重放隐藏、lsof 输出解析与筛选。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@Suite("@browser 与开发服务器检测")
struct BrowserMentionTests {
    @Test("@browser 只在开头或空白之后、且后面不是名称字符时算提及")
    func mentionBoundaries() {
        #expect(BrowserMention.isMentioned(in: "@browser 看看首页"))
        #expect(BrowserMention.isMentioned(in: "帮我 @browser 测试登录"))
        #expect(BrowserMention.isMentioned(in: "用 @browser"))
        #expect(!BrowserMention.isMentioned(in: "a@browser.com"))
        #expect(!BrowserMention.isMentioned(in: "@browsers 列表"))
        #expect(!BrowserMention.isMentioned(in: "@browser-use 是什么"))
        #expect(!BrowserMention.isMentioned(in: "没有提及"))
    }

    @Test("提示块:有开发服务器时列出并要求复用,没有时提示先自查;标记可被识别")
    func hintContent() {
        let with = BrowserMention.hint(servers: [DevServer(port: 5173, command: "node", pid: 10, cwd: "/p/web")])
        #expect(with.contains("http://localhost:5173") && with.contains("do NOT start a duplicate") && with.contains("cwd /p/web"))
        #expect(BrowserMention.isHint(with))
        let without = BrowserMention.hint(servers: [])
        #expect(without.contains("No running dev server") && without.contains("lsof"))
        #expect(!BrowserMention.isHint("普通消息"))
    }

    @Test("补全:空查询与模糊匹配出现 @browser,不相关查询不出现")
    func completion() {
        #expect(CompletionEngine.browserMentionItems(query: "").first?.insertText == "@browser ")
        #expect(CompletionEngine.browserMentionItems(query: "brow").first?.kind == .browser)
        #expect(CompletionEngine.browserMentionItems(query: "zzz").isEmpty)
    }

    @Test("历史重放:@browser 附加的提示块不进入用户消息,真正的用户文字保留")
    @MainActor
    func replayHidesHint() {
        let store = TimelineStore()
        store.apply(.userMessageChunk(messageId: "m1", content: .text("@browser 看看首页")))
        store.apply(.userMessageChunk(messageId: "m1", content: .text(BrowserMention.hint(servers: []))))
        let users = store.entries.filter { $0.kind == .user }
        #expect(users.count == 1 && users[0].text == "@browser 看看首页")
    }

    @Test("解析 lsof 监听输出:只保留回环/通配地址,端口取最后一段,同一进程同端口去重")
    func parseListening() {
        let output = """
        p100
        cnode
        n127.0.0.1:5173
        n[::1]:5173
        p200
        cControlCe
        n*:5000
        p300
        cpython3
        n192.168.1.5:8000
        n*:8001
        """
        let parsed = DevServerDetector.parseListening(output)
        #expect(parsed.map(\.port) == [5173, 5000, 8001])
        #expect(parsed[0].pid == 100 && parsed[0].command == "node")
    }

    @Test("筛选:工作区内的进程排最前;系统端口与非开发进程被排除;其余只保留常见 Web 开发进程")
    func selection() {
        let listening: [(pid: Int, command: String, port: Int)] = [
            (1, "node", 3000), (2, "ControlCe", 5000), (3, "Postgres", 5432), (4, "myserver", 9000), (5, "python3", 8000), (6, "node", 80),
        ]
        let cwds = [1: "/other", 4: "/ws/app", 5: "/elsewhere"]
        let servers = DevServerDetector.select(listening, cwds: cwds, workspace: "/ws")
        #expect(servers.map(\.port) == [9000, 3000, 8000], "工作区内的 myserver 排最前,然后按端口排;5000/5432/80 被排除")
        #expect(servers.first?.cwd == "/ws/app")
        #expect(DevServerDetector.parseCwd("p4\nn/ws/app\np5\nn/x") == [4: "/ws/app", 5: "/x"])
    }
}
