// @author ixxxxoooo
// Agent 改动块的稳定标识:还原其它块导致行号移动后,已保留的块仍被识别。

import DiffKit
import Foundation
import Testing
@testable import OhMyAgentApp

@Suite("Agent 改动块审阅")
struct AgentHunkKeyTests {
    private let old = (1...30).map { "line\($0)" }.joined(separator: "\n") + "\n"

    private func modified(_ edits: [Int: String]) -> String {
        (1...30).map { edits[$0] ?? "line\($0)" }.joined(separator: "\n") + "\n"
    }

    @Test("保留一个块后只剩另一个;位置移动不影响标识")
    func acceptAndShift() {
        let new = modified([3: "A", 25: "B"])
        let hunks = LineDiff.diff(old: old, new: new, context: 0).hunks
        #expect(hunks.count == 2)
        let first = AgentHunkKey.key(hunks[0])
        let pending = AgentHunkKey.pending(hunks, accepted: [first])
        #expect(pending.count == 1 && AgentHunkKey.key(pending[0]) != first)
        // 在文件开头多插入两行:块内容不变,位置变化,标识不变
        let shifted = "x\ny\n" + new
        let shiftedHunks = LineDiff.diff(old: "x\ny\n" + old, new: shifted, context: 0).hunks
        #expect(shiftedHunks.map(AgentHunkKey.key) == hunks.map(AgentHunkKey.key))
    }

    @Test("块的起始行取第一条新增行;纯删除取 newStart")
    func firstLine() {
        let added = LineDiff.diff(old: old, new: modified([7: "X"]), context: 0).hunks
        #expect(AgentHunkKey.firstLine(of: added[0]) == 7)
        let removed = LineDiff.diff(old: old, new: old.replacingOccurrences(of: "line9\n", with: ""), context: 0).hunks
        #expect(AgentHunkKey.firstLine(of: removed[0]) >= 1)
    }

    @Test("全部保留后没有待审阅的块")
    func acceptAll() {
        let hunks = LineDiff.diff(old: old, new: modified([2: "A", 10: "B", 20: "C"]), context: 0).hunks
        #expect(AgentHunkKey.pending(hunks, accepted: Set(hunks.map(AgentHunkKey.key))).isEmpty)
    }
}
