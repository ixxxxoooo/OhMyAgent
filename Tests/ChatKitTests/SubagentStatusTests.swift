// @author ixxxxoooo
// 子代理状态测试:启动中 → 运行中 → 完成/失败、后台运行、待办计数、当前活动、父会话等待的前台子代理数。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("子代理状态")
struct SubagentStatusTests {
    /// 在存储里放一个子代理工具调用。
    private func launch(_ store: TimelineStore, id: String = "sub1", background: Bool = false, status: ToolStatus = .inProgress) -> TimelineEntry {
        let tool = ToolCall(toolCallId: id, name: "Task", title: "审查路由", kind: .other, status: status,
                            rawInput: ["description": "审查路由", "subagent_type": "code-reviewer", "run_in_background": .bool(background)])
        store.apply(.toolCall(tool))
        return store.entries.last!
    }

    private func child(_ store: TimelineStore, _ update: SessionUpdate, parent: String = "sub1") {
        store.apply(.childUpdate(parent: parent, update: update))
    }

    @Test("刚派发、内部没有产出:启动中")
    func starting() throws {
        let store = TimelineStore()
        let entry = launch(store)
        let status = try #require(SubagentStatus.make(entry: entry))
        #expect(status.phase == .starting && status.isActive)
        #expect(status.todoTotal == 0 && status.activityText == nil && status.toolUses == 0)
    }

    @Test("内部有产出后进入运行中,并给出当前活动与工具调用数")
    func running() throws {
        let store = TimelineStore()
        let entry = launch(store)
        child(store, .agentThoughtChunk(messageId: nil, content: .text("先看看 Router.swift\n再看 Session.swift")))
        var status = try #require(SubagentStatus.make(entry: entry))
        #expect(status.phase == .running)
        #expect(status.activityKind == .thinking && status.activityText == "再看 Session.swift")
        child(store, .toolCall(ToolCall(toolCallId: "r1", name: "Read", title: "读取 Router.swift", kind: .read, status: .inProgress)))
        status = try #require(SubagentStatus.make(entry: entry))
        #expect(status.activityKind == .tool && status.activityText == "读取 Router.swift" && status.toolUses == 1)
    }

    @Test("待办计数取最近一次更新")
    func todos() throws {
        let store = TimelineStore()
        let entry = launch(store)
        child(store, .plan([PlanEntry(content: "a", status: "completed"), PlanEntry(content: "b", status: "in_progress"), PlanEntry(content: "c")]))
        var status = try #require(SubagentStatus.make(entry: entry))
        #expect(status.todoDone == 1 && status.todoTotal == 3)
        child(store, .plan([PlanEntry(content: "a", status: "completed"), PlanEntry(content: "b", status: "completed"), PlanEntry(content: "c", status: "completed")]))
        status = try #require(SubagentStatus.make(entry: entry))
        #expect(status.todoDone == 3 && status.todoTotal == 3)
    }

    @Test("完成与失败是终态,不再有当前活动")
    func terminal() throws {
        let store = TimelineStore()
        let done = launch(store, id: "ok", status: .completed)
        child(store, .agentMessageChunk(messageId: nil, content: .text("已审查完")), parent: "ok")
        let ok = try #require(SubagentStatus.make(entry: done))
        #expect(ok.phase == .completed && !ok.isActive && ok.activityText == nil)
        let bad = launch(store, id: "bad", status: .failed)
        #expect(SubagentStatus.make(entry: bad)?.phase == .failed)
    }

    @Test("后台子代理:阶段为后台运行,且不计入父会话在等待的前台子代理")
    func background() throws {
        let store = TimelineStore()
        let bg = launch(store, id: "bg", background: true)
        _ = launch(store, id: "fg1")
        _ = launch(store, id: "fg2")
        _ = launch(store, id: "done", status: .completed)
        #expect(SubagentStatus.make(entry: bg)?.phase == .backgroundRunning)
        #expect(store.runningForegroundSubagentCount() == 2)
        #expect(store.runningBackgroundSubagents().map(\.entry.id) == [bg.id], "任务坞只含运行中的后台子代理")
    }

    @Test("非工具条目没有子代理状态")
    func nonTool() {
        #expect(SubagentStatus.make(entry: TimelineEntry(kind: .assistant, text: "hi")) == nil)
    }
}
