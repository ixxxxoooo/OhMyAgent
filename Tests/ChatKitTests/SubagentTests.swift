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

    @Test("刚启动、还没有内部内容的 Task 也算子 Agent(任务坞不能漏掉)")
    func launchWithoutChildIsListed() {
        let store = TimelineStore()
        store.apply(.toolCall(ToolCall(toolCallId: "t1", name: "Task", title: "审计依赖", kind: .other, status: .inProgress)))
        store.apply(.toolCall(ToolCall(toolCallId: "t2", name: "task", title: "OpenCode 子任务", kind: .other, status: .inProgress)))
        store.apply(.toolCall(ToolCall(toolCallId: "t3", name: "TaskCreate", title: "待办", kind: .other, status: .inProgress)))
        #expect(store.subagentEntries().map { $0.entry.tool?.toolCallId } == ["t1", "t2"])
    }

    @Test("子 Agent 统计:工具次数取内部时间线,usage 文本覆盖耗时与 token")
    func summaryFromTimelineAndUsage() throws {
        let store = makeStore()
        let entry = try #require(store.toolEntry(id: "sub_1"))
        let plain = try #require(SubagentSummary.make(entry: entry))
        #expect(plain.toolUses == 3)   // r1、sub_2、g1
        #expect(plain.totalTokens == nil)

        store.apply(.toolCallUpdate(toolCallId: "sub_1", raw: [
            "status": "completed",
            "content": [["type": "content", "content": ["type": "text", "text": "完成\n<usage>total_tokens: 3400\ntool_uses: 7\nduration_ms: 72000</usage>"]]],
        ]))
        let finished = try #require(store.toolEntry(id: "sub_1"))
        let done = try #require(SubagentSummary.make(entry: finished))
        #expect(done.toolUses == 7)
        #expect(done.totalTokens == 3400)
        #expect(done.durationSeconds == 72)
        #expect(done.parts.contains { $0.contains("3.4K") })
    }

    @Test("usage 解析与紧凑数字")
    func usageParsing() {
        let usage = SubagentSummary.parseUsage(from: "total_tokens: 12\ntool_uses: 2")
        #expect(usage.totalTokens == 12 && usage.toolUses == 2 && usage.durationMs == nil)
        #expect(SubagentSummary.compact(950) == "950")
        #expect(SubagentSummary.compact(1_200_000) == "1.2M")
    }
}
