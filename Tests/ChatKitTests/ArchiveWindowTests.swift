// @author ixxxxoooo
// 存档回显窗口:轮开头识别、保留最近 N 轮、折叠阈值。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@Suite("存档回显窗口")
struct ArchiveWindowTests {
    private func user(_ text: String = "问") -> JSONValue { ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": .string(text)]] }
    private func agent(_ text: String = "答") -> JSONValue { ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(text)]] }
    private func tool() -> JSONValue { ["sessionUpdate": "tool_call", "toolCallId": "t"] }

    /// 构造 n 轮:每轮 = 用户(拆成 2 个块) + 助手 + 工具。
    private func turns(_ n: Int) -> [JSONValue] {
        (0..<n).flatMap { _ in [user("a"), user("b"), agent(), tool()] }
    }

    @Test("用户消息拆成多个块只算一个轮开头")
    func chunkedUserIsOneTurn() {
        #expect(ArchiveWindow.turnStarts(turns(3)) == [0, 4, 8])
        #expect(ArchiveWindow.turnStarts([]).isEmpty)
    }

    @Test("轮数不够多时完整回显")
    func shortSessionNotCut() {
        let cut = ArchiveWindow.cut(turns(45), keepTurns: 40)   // 只会折叠 5 轮,低于阈值
        #expect(cut == ArchiveWindowCut(start: 0, hiddenTurns: 0, keptTurns: 45))
    }

    @Test("长会话只保留最近 N 轮,起点落在轮开头")
    func longSessionCut() {
        let updates = turns(60)
        let cut = ArchiveWindow.cut(updates, keepTurns: 40)
        #expect(cut.hiddenTurns == 20 && cut.keptTurns == 40)
        #expect(cut.start == 20 * 4)
        #expect(updates[cut.start]["sessionUpdate"]?.stringValue == "user_message_chunk")
        #expect(ArchiveWindow.turnStarts(Array(updates[cut.start...])).count == 40)
    }

    @Test("keepTurns 为 nil 完整回显;非法值按 1 处理")
    func fullAndClamped() {
        let updates = turns(60)
        #expect(ArchiveWindow.cut(updates, keepTurns: nil).start == 0)
        #expect(ArchiveWindow.cut(updates, keepTurns: 0).keptTurns == 1)
    }

    @Test("开场提示(第一个用户消息之前)随被折叠的部分一起跳过")
    func preambleSkipped() {
        let updates = [agent("开场")] + turns(50)
        let cut = ArchiveWindow.cut(updates, keepTurns: 10)
        #expect(cut.hiddenTurns == 40)
        #expect(cut.start == 1 + 40 * 4)
    }
}
