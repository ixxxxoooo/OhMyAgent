// @author ygw
// ChatKit 测试:时间线归并、Markdown 解析、事件合并、与 FakeAgent 的端到端会话。

import ACPKit
import AgentHost
import Foundation
import Testing

@testable import ChatKit

@MainActor
@Suite("时间线归并")
struct TimelineStoreTests {
    @Test("同一消息的分片归并为一条,思维结束后开始助手文本")
    func mergesChunks() {
        let store = TimelineStore()
        store.appendUser("你好")
        store.apply(.agentThoughtChunk(messageId: "m1", content: .text("想")))
        store.apply(.agentThoughtChunk(messageId: "m1", content: .text("一下")))
        store.apply(.agentMessageChunk(messageId: "m2", content: .text("答")))
        store.apply(.agentMessageChunk(messageId: "m2", content: .text("复")))
        #expect(store.entries.map(\.kind) == [.user, .thought, .assistant])
        #expect(store.entries[1].text == "想一下")
        #expect(store.entries[1].isStreaming == false)
        #expect(store.entries[2].text == "答复")
        #expect(store.entries[2].isStreaming == true)
        store.finishStreaming()
        #expect(store.entries[2].isStreaming == false)
    }

    @Test("工具调用增量更新同一条目")
    func toolUpdates() {
        let store = TimelineStore()
        store.apply(.toolCall(ToolCall(toolCallId: "t1", title: "读取", kind: .read, status: .pending)))
        store.apply(.toolCallUpdate(toolCallId: "t1", raw: ["status": "completed", "title": "已读取"]))
        #expect(store.entries.count == 1)
        #expect(store.entries[0].tool?.status == .completed)
        #expect(store.entries[0].tool?.title == "已读取")
        #expect(store.entries[0].tool?.kind == .read)
    }

    @Test("未见过的工具更新会创建条目;计划原地更新")
    func unknownToolAndPlan() {
        let store = TimelineStore()
        store.apply(.toolCallUpdate(toolCallId: "x", raw: ["toolCallId": "x", "title": "孤立更新", "status": "in_progress"]))
        #expect(store.entries.count == 1)
        store.apply(.plan([PlanEntry(content: "a", priority: "high", status: "pending")]))
        store.apply(.plan([PlanEntry(content: "a", priority: "high", status: "completed")]))
        #expect(store.entries.filter { $0.kind == .plan }.count == 1)
        #expect(store.entries.last?.plan.first?.status == "completed")
    }

    @Test("工具调用打断文本流后,后续文本为新条目")
    func toolSplitsText() {
        let store = TimelineStore()
        store.apply(.agentMessageChunk(messageId: nil, content: .text("前")))
        store.apply(.toolCall(ToolCall(toolCallId: "t", title: "跑", kind: .execute)))
        store.apply(.agentMessageChunk(messageId: nil, content: .text("后")))
        #expect(store.entries.map(\.kind) == [.assistant, .tool, .assistant])
    }
}

@Suite("Markdown 块解析")
struct MarkdownParserTests {
    @Test("标题、段落、列表、引用、分隔线")
    func basicBlocks() {
        let blocks = MarkdownParser.parse("# 标题\n\n正文第一行\n正文第二行\n\n- 甲\n- 乙\n  - 乙一\n\n> 引用\n\n---")
        #expect(blocks.count == 5)
        #expect(blocks[0] == .heading(level: 1, text: "标题"))
        #expect(blocks[1] == .paragraph("正文第一行\n正文第二行"))
        guard case .list(let items) = blocks[2] else { Issue.record("应为列表"); return }
        #expect(items.count == 3)
        #expect(items[2].level == 1)
        #expect(blocks[3] == .quote("引用"))
        #expect(blocks[4] == .rule)
    }

    @Test("代码围栏与流式中未闭合的围栏")
    func fences() {
        let closed = MarkdownParser.parse("前\n```swift\nlet a = 1\n```\n后")
        #expect(closed == [.paragraph("前"), .code(language: "swift", code: "let a = 1", isClosed: true), .paragraph("后")])
        let open = MarkdownParser.parse("```py\nprint(1)\nprint(2)")
        #expect(open == [.code(language: "py", code: "print(1)\nprint(2)", isClosed: false)])
    }

    @Test("有序列表、任务列表与表格")
    func listsAndTables() {
        let blocks = MarkdownParser.parse("1. 一\n2. 二\n\n- [x] 完成\n- [ ] 待办\n\n| 名称 | 值 |\n| --- | --- |\n| a | 1 |\n| b | 2 |")
        guard case .list(let ordered) = blocks[0], case .list(let tasks) = blocks[1], case .table(let header, let rows) = blocks[2] else {
            Issue.record("块类型不符: \(blocks)"); return
        }
        #expect(ordered.map(\.marker) == ["1.", "2."])
        #expect(tasks.map(\.checked) == [true, false])
        #expect(header == ["名称", "值"])
        #expect(rows == [["a", "1"], ["b", "2"]])
    }
}

@Suite("事件合并")
struct CoalescerTests {
    @Test("窗口内的事件合并为一个批次且保持顺序")
    func batches() async {
        let coalescer = EventCoalescer(interval: .milliseconds(20))
        for index in 0..<50 { coalescer.push(.stderr("\(index)")) }
        var first: [ClientEvent] = []
        for await batch in coalescer.batches {
            first = batch
            break
        }
        #expect(first.count == 50)
        let texts = first.compactMap { event -> String? in
            if case .stderr(let text) = event { return text }
            return nil
        }
        #expect(texts == (0..<50).map(String.init))
    }
}

@MainActor
@Suite("会话端到端(FakeAgent 子进程)")
struct SessionModelTests {
    /// 查找 FakeAgent 可执行文件。
    static func fakeAgentPath() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let candidates = ["\(root)/.build/out/Products/Debug", "\(root)/.build/debug", "\(root)/.build/arm64-apple-macosx/debug"]
        let dir = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: "\($0)/FakeAgent") })
        return "\(dir)/FakeAgent"
    }

    /// 等待条件成立。
    static func wait(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("连接后发送消息得到流式回复,工具调用经权限批准完成")
    func fullTurn() async throws {
        let descriptor = AgentDescriptor(id: "fake", name: "Fake", kind: .genericACP, command: try Self.fakeAgentPath())
        let model = SessionModel(workspace: URL(fileURLWithPath: NSTemporaryDirectory()), descriptor: descriptor)
        model.connect()
        #expect(await Self.wait { model.phase == .ready })
        #expect(model.sessionId != nil)

        model.send("你好")
        #expect(await Self.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .assistant } })
        #expect(model.timeline.entries.first?.kind == .user)
        #expect(model.timeline.entries.allSatisfy { !$0.isStreaming })

        model.send("请调用工具 tool")
        #expect(await Self.wait { !model.pendingPermissions.isEmpty })
        let prompt = try #require(model.pendingPermissions.first)
        let allow = try #require(prompt.request.options.first { $0.kind == .allowOnce })
        model.resolve(prompt, optionId: allow.optionId)
        #expect(await Self.wait { !model.isRunning })
        let tool = try #require(model.timeline.entries.first { $0.kind == .tool })
        #expect(tool.tool?.status == .completed)
        model.shutdown()
    }

    @Test("连接前发送的消息会排队并在就绪后自动发出")
    func queuedPrompt() async throws {
        let descriptor = AgentDescriptor(id: "fake", name: "Fake", kind: .genericACP, command: try Self.fakeAgentPath())
        let model = SessionModel(workspace: URL(fileURLWithPath: NSTemporaryDirectory()), descriptor: descriptor)
        model.send("先发送")
        #expect(model.queuedPrompt == "先发送")
        #expect(await Self.wait { model.timeline.entries.contains { $0.kind == .assistant } && !model.isRunning })
        model.shutdown()
    }

    @Test("缺少可执行文件时进入失败状态并给出原因")
    func failure() async {
        let descriptor = AgentDescriptor(id: "bad", name: "Bad", kind: .genericACP, command: "/nonexistent/agent")
        let model = SessionModel(workspace: URL(fileURLWithPath: NSTemporaryDirectory()), descriptor: descriptor)
        model.connect()
        #expect(await Self.wait { if case .failed = model.phase { return true } else { return false } })
        model.shutdown()
    }
}
