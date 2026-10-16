// @author ixxxxoooo
// 多层子 Agent:更新归并到正确层级、按 ID 跨层查找、子 Agent 列表深度与状态。

import ACPKit
import Testing
@testable import ChatKit

@MainActor
@Suite("子 Agent 时间线")
struct SubagentTests {
    private func child(of parent: String, _ update: SessionUpdate) -> SessionUpdate {
        .childUpdate(parent: parent, update: update)
    }

    /// 构造:root → sub_1 → sub_2 两层子 Agent。
    private func makeStore() -> TimelineStore {
        let store = TimelineStore()
        store.apply(.toolCall(ToolCall(toolCallId: "sub_1", title: "子任务 A", kind: .other, status: .inProgress)))
        store.apply(child(of: "sub_1", .toolCall(ToolCall(toolCallId: "r1", title: "读取", kind: .read, status: .completed))))
        store.apply(child(of: "sub_1", .toolCall(ToolCall(toolCallId: "sub_2", title: "子任务 B", kind: .other, status: .inProgress))))
        store.apply(child(of: "sub_2", .toolCall(ToolCall(toolCallId: "g1", title: "搜索", kind: .search, status: .completed))))
        return store
    }

    @Test("第二层子 Agent 的更新进入第二层子存储,而不是被拍平到根")
    func nestedRouting() throws {
        let store = makeStore()
        #expect(store.entries.count == 1)
        let first = try #require(store.toolEntry(id: "sub_1"))
        let firstChild = try #require(first.childStore)
        #expect(firstChild.entries.map { $0.tool?.toolCallId } == ["r1", "sub_2"])
        let second = try #require(firstChild.toolEntry(id: "sub_2"))
        #expect(second.childStore?.entries.map { $0.tool?.toolCallId } == ["g1"])
    }

    @Test("按 ID 跨层查找;不存在返回 nil")
    func findAcrossLevels() {
        let store = makeStore()
        #expect(store.toolEntry(id: "g1")?.tool?.title == "搜索")
        #expect(store.toolEntry(id: "sub_2")?.tool?.title == "子任务 B")
        #expect(store.toolEntry(id: "nope") == nil)
    }

    @Test("子 Agent 列表按深度优先并带深度;状态可随更新变化")
    func subagentList() throws {
        let store = makeStore()
        let list = store.subagentEntries()
        #expect(list.map { $0.entry.tool?.toolCallId } == ["sub_1", "sub_2"])
        #expect(list.map(\.depth) == [0, 1])
        store.apply(child(of: "sub_1", .toolCallUpdate(toolCallId: "sub_2", raw: ["status": "completed"])))
        #expect(try #require(store.toolEntry(id: "sub_2")).tool?.status == .completed)
        #expect(try #require(store.toolEntry(id: "sub_1")).tool?.status == .inProgress)
    }

    @Test("没有子 Agent 的工具不出现在列表中")
    func plainToolsExcluded() {
        let store = TimelineStore()
        store.apply(.toolCall(ToolCall(toolCallId: "t", title: "读取", kind: .read, status: .completed)))
        #expect(store.subagentEntries().isEmpty)
    }
}
