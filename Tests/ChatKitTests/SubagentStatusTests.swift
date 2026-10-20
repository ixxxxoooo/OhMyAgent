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

@Suite("子代理当前活动行提取")
struct SubagentLastLineTests {
    @Test("取最后一个非空行并去首尾空白")
    func lastNonEmpty() {
        #expect(SubagentStatus.lastLine("第一行\n第二行\n  末行  \n\n \n") == "末行")
        #expect(SubagentStatus.lastLine("只有一行") == "只有一行")
        #expect(SubagentStatus.lastLine("a\n") == "a")
    }

    @Test("全空白或空串返回 nil")
    func blank() {
        #expect(SubagentStatus.lastLine("") == nil)
        #expect(SubagentStatus.lastLine("\n  \n\t\n") == nil)
    }

    @Test("超过 80 字符截断并加省略号")
    func truncates() {
        let long = String(repeating: "长", count: 100)
        let line = SubagentStatus.lastLine("前文\n\(long)")
        #expect(line == String(repeating: "长", count: 80) + "…")
    }

    @Test("超长文本只扫描尾部也能正确返回")
    func hugeText() {
        let big = (0..<20000).map { "行\($0)" }.joined(separator: "\n") + "\n\n"
        #expect(SubagentStatus.lastLine(big) == "行19999")
    }
}

/// 异步启动的子 Agent:工具结果先返回(状态完成),子 Agent 仍在后台运行,直到回合结束。
@MainActor
@Suite("异步子代理")
struct AsyncSubagentTests {
    private func launchAsync(_ store: TimelineStore) -> TimelineEntry {
        let tool = ToolCall(toolCallId: "a1", name: "Agent", title: "后台审查", kind: .other, status: .inProgress,
                            rawInput: ["description": "后台审查", "subagent_type": "Explore"])
        store.apply(.toolCall(tool))
        // 适配器的完成更新:状态 completed + toolResponse 标记 async_launched
        store.apply(.toolCallUpdate(toolCallId: "a1", raw: [
            "status": "completed",
            "_meta": ["claudeCode": ["toolResponse": ["status": "async_launched", "isAsync": .bool(true)]]],
        ]))
        return store.entries.last!
    }

    @Test("异步启动后工具已完成,但子代理仍显示后台运行并进任务坞")
    func stillRunning() throws {
        let store = TimelineStore()
        let entry = launchAsync(store)
        #expect(entry.tool?.status == .completed)
        #expect(entry.tool?.asyncRunning == true)
        let status = try #require(SubagentStatus.make(entry: entry))
        #expect(status.phase == .backgroundRunning && status.isActive)
        #expect(store.runningBackgroundSubagents().count == 1)
        #expect(store.runningForegroundSubagentCount() == 0)
    }

    @Test("后续的普通更新不会清掉异步标记;回合结束后才变为已完成")
    func clearsAtTurnEnd() throws {
        let store = TimelineStore()
        let entry = launchAsync(store)
        store.apply(.toolCallUpdate(toolCallId: "a1", raw: ["title": "后台审查 · 更新"]))
        #expect(entry.tool?.asyncRunning == true)
        store.finishTurn()
        #expect(entry.tool?.asyncRunning == false)
        let status = try #require(SubagentStatus.make(entry: entry))
        #expect(status.phase == .completed)
        #expect(store.runningBackgroundSubagents().isEmpty)
    }

    @Test("同步子代理没有异步标记,完成即完成")
    func syncUnaffected() throws {
        let store = TimelineStore()
        store.apply(.toolCall(ToolCall(toolCallId: "s1", name: "Task", title: "x", kind: .other, status: .inProgress)))
        store.apply(.toolCallUpdate(toolCallId: "s1", raw: ["status": "completed"]))
        let entry = try #require(store.entries.last)
        #expect(entry.tool?.asyncRunning == false)
        #expect(try #require(SubagentStatus.make(entry: entry)).phase == .completed)
    }
}
