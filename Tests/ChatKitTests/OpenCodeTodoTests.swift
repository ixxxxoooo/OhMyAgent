// @author ixxxxoooo
// OpenCode 的待办工具(todowrite)适配测试:载荷取自真实会话存档——
// 它只发一个标题为「14 todos」的 `other` 类工具调用,待办在 rawInput.todos 里,没有 ACP `plan` 更新。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@MainActor
@Suite("OpenCode 待办适配")
struct OpenCodeTodoTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func todoCall() throws -> ToolCall {
        ToolCall(json: try json(#"""
        {"toolCallId":"t1","title":"2 todos","kind":"other","status":"pending",
         "rawInput":{"todos":[{"content":"新增 pyproject.toml","priority":"high","status":"pending"},
                              {"content":"补单测","priority":"medium","status":"in_progress"}]}}
        """#))
    }

    @Test("带 todos 的工具调用并入待办清单,不单独成工具行")
    func todoToolBecomesPlan() throws {
        let store = TimelineStore()
        store.apply(.toolCall(try todoCall()))
        #expect(store.entries.filter { $0.kind == .tool }.isEmpty)
        let plan = store.entries.first { $0.kind == .plan }
        #expect(plan?.plan.map(\.content) == ["新增 pyproject.toml", "补单测"])
        #expect(plan?.plan.last?.status == "in_progress")
    }

    @Test("同一工具的后续更新被吞掉;再次写入更新同一份清单")
    func laterUpdatesMerge() throws {
        let store = TimelineStore()
        store.apply(.toolCall(try todoCall()))
        store.apply(.toolCallUpdate(toolCallId: "t1", raw: try json(#"{"toolCallId":"t1","status":"completed"}"#)))
        #expect(store.entries.filter { $0.kind == .tool }.isEmpty)
        let next = ToolCall(json: try json(#"""
        {"toolCallId":"t2","title":"2 todos","kind":"other","status":"completed",
         "rawInput":{"todos":[{"content":"新增 pyproject.toml","priority":"high","status":"completed"},
                              {"content":"补单测","priority":"medium","status":"completed"}]}}
        """#))
        store.apply(.toolCall(next))
        #expect(store.entries.filter { $0.kind == .plan }.count == 1)
        #expect(store.entries.first { $0.kind == .plan }?.plan.allSatisfy { $0.status == "completed" } == true)
    }

    @Test("先到的是不带入参的占位行:拿到 todos 后撤掉占位")
    func placeholderRemoved() throws {
        let store = TimelineStore()
        store.apply(.toolCall(ToolCall(toolCallId: "t1", kind: .other, status: .pending)))
        #expect(store.entries.filter { $0.kind == .tool }.count == 1)
        store.apply(.toolCallUpdate(toolCallId: "t1", raw: try json(#"{"toolCallId":"t1","rawInput":{"todos":[{"content":"a","status":"pending"}]}}"#)))
        #expect(store.entries.filter { $0.kind == .tool }.isEmpty)
        #expect(store.entries.first { $0.kind == .plan }?.plan.count == 1)
    }

    @Test("普通工具入参、空 todos、缺内容的 todos 都不识别")
    func nonTodoInputs() throws {
        #expect(TimelineStore.todoEntries(in: try json(#"{"command":"ls"}"#)) == nil)
        #expect(TimelineStore.todoEntries(in: try json(#"{"todos":[]}"#)) == nil)
        #expect(TimelineStore.todoEntries(in: try json(#"{"todos":[{"status":"pending"}]}"#)) == nil)
        #expect(TimelineStore.todoEntries(in: nil) == nil)
    }
}
