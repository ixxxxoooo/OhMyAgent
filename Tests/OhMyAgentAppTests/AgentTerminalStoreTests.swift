// @author ixxxxoooo
// Agent 终端:面板里的条目管理、输出换行转换与会话的非追加变化计数。

import ChatKit
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("Agent 终端面板")
struct AgentTerminalStoreTests {
    private func session(_ id: String) -> TerminalSession { TerminalSession(id: id, command: "cmd \(id)", isExternal: true) }

    @Test("打开:去重、激活;激活不存在的终端无效;回到用户终端")
    func openAndActivate() {
        let store = AgentTerminalStore()
        let a = session("a"), b = session("b")
        store.open(a, root: "/p")
        store.open(b, root: "/p")
        store.open(a, root: "/p")
        #expect(store.entries(for: "/p").map(\.id) == ["a", "b"])
        #expect(store.activeID(for: "/p") == "a")
        store.activate("zzz", root: "/p")
        #expect(store.activeID(for: "/p") == "a")
        store.activate(nil, root: "/p")
        #expect(store.activeID(for: "/p") == nil)
        #expect(store.entries(for: "/other").isEmpty)
    }

    @Test("关闭激活项回到用户终端,关闭最后一个清空条目")
    func close() {
        let store = AgentTerminalStore()
        store.open(session("a"), root: "/p")
        store.open(session("b"), root: "/p")
        store.close("b", root: "/p")
        #expect(store.activeID(for: "/p") == nil)
        #expect(store.entries(for: "/p").map(\.id) == ["a"])
        store.close("a", root: "/p")
        #expect(store.entries(for: "/p").isEmpty)
    }

    @Test("换行转换:裸 LF 补 CR,已有 CRLF 不重复,CR 与 LF 被拆在两段时也不重复")
    func crlf() {
        var cr = false
        #expect(AgentTerminalFeed.crlf(Array("a\nb\r\nc".utf8)[...], previousWasCR: &cr) == Array("a\r\nb\r\nc".utf8))
        #expect(!cr)
        var split = false
        let first = AgentTerminalFeed.crlf(Array("x\r".utf8)[...], previousWasCR: &split)
        let second = AgentTerminalFeed.crlf(Array("\ny\n".utf8)[...], previousWasCR: &split)
        #expect(first + second == Array("x\r\ny\r\n".utf8))
    }
}
