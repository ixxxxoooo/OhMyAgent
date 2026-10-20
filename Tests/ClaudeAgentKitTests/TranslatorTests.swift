// @author ixxxxoooo
// 翻译层测试:工具调用上报、流式去重、计划、子 Agent 标注与提示转换。

import ACPKit
import Foundation
import Testing
@testable import ClaudeAgentKit

private func makeTranslator(terminal: Bool = false) -> MessageTranslator {
    MessageTranslator(renderer: ToolCallRenderer(capabilities: ToolRenderCapabilities(terminalOutput: terminal)), cwd: "/work")
}

private func assistant(_ blocks: [JSONValue], id: String = "msg_1", parent: String? = nil) -> JSONValue {
    JSONValue.make([("type", "assistant"), ("message", ["id": .string(id), "role": "assistant", "content": .array(blocks)]), ("parent_tool_use_id", parent.map(JSONValue.string))])
}

private func userResult(_ id: String, _ text: String, error: Bool = false, structured: JSONValue? = nil) -> JSONValue {
    JSONValue.make([
        ("type", "user"), ("uuid", "u1"),
        ("message", ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": .string(text), "is_error": .bool(error)]]]),
        ("tool_use_result", structured),
    ])
}

@Suite("翻译层")
struct TranslatorTests {
    @Test("tool_use 先发 tool_call,再次出现发 tool_call_update 细化")
    func toolUseThenRefinement() {
        var translator = makeTranslator()
        let block: JSONValue = ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/work/a.swift"]]
        let first = translator.translateMessage(assistant([block]), forwardSubagentText: false)
        #expect(first.count == 1)
        #expect(first[0]["sessionUpdate"]?.stringValue == "tool_call")
        #expect(first[0]["kind"]?.stringValue == "read")
        #expect(first[0]["status"]?.stringValue == "pending")
        let second = translator.translateMessage(assistant([block]), forwardSubagentText: false)
        #expect(second[0]["sessionUpdate"]?.stringValue == "tool_call_update")
    }

    @Test("tool_result 翻译为完成状态的 tool_call_update 并清理缓存")
    func toolResultCompletes() {
        var translator = makeTranslator()
        _ = translator.translateMessage(assistant([["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/work/a.swift"]]]), forwardSubagentText: false)
        let updates = translator.translateMessage(userResult("t1", "内容"), forwardSubagentText: false)
        let last = updates.last
        #expect(last?["sessionUpdate"]?.stringValue == "tool_call_update")
        #expect(last?["toolCallId"]?.stringValue == "t1")
        #expect(last?["status"]?.stringValue == "completed")
        #expect(translator.toolUse(id: "t1") == nil)
        let failed = {
            var inner = makeTranslator()
            _ = inner.translateMessage(assistant([["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "false"]]]), forwardSubagentText: false)
            return inner.translateMessage(userResult("t2", "boom", error: true), forwardSubagentText: false).last
        }()
        #expect(failed?["status"]?.stringValue == "failed")
    }

    @Test("流式文本已发送后,完整 assistant 消息只补发未发送的尾部")
    func streamedTextDedup() {
        var translator = makeTranslator()
        _ = translator.translateStreamEvent(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "msg_1"]]])
        let delta = translator.translateStreamEvent(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "你好"]]])
        #expect(delta.count == 1)
        #expect(delta[0]["messageId"]?.stringValue == "msg_1")
        #expect(delta[0]["content"]?["text"]?.stringValue == "你好")
        let rest = translator.translateMessage(assistant([["type": "text", "text": "你好,世界"]]), forwardSubagentText: false)
        #expect(rest.count == 1)
        #expect(rest[0]["content"]?["text"]?.stringValue == ",世界")
        let again = translator.translateMessage(assistant([["type": "text", "text": "新的一段"]]), forwardSubagentText: false)
        #expect(again[0]["content"]?["text"]?.stringValue == "新的一段")
    }

    @Test("完全流式发送过的文本不再重复")
    func fullyStreamedNotRepeated() {
        var translator = makeTranslator()
        _ = translator.translateStreamEvent(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "m"]]])
        _ = translator.translateStreamEvent(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "完整"]]])
        #expect(translator.translateMessage(assistant([["type": "text", "text": "完整"]]), forwardSubagentText: false).isEmpty)
    }

    @Test("思考块翻译为 agent_thought_chunk")
    func thinking() {
        var translator = makeTranslator()
        let updates = translator.translateMessage(assistant([["type": "thinking", "thinking": "想想", "signature": "s"]]), forwardSubagentText: false)
        #expect(updates.first?["sessionUpdate"]?.stringValue == "agent_thought_chunk")
    }

    @Test("TodoWrite 转为 plan 条目,进行中条目使用 activeForm")
    func todoWritePlan() {
        var translator = makeTranslator()
        let todos: JSONValue = [["content": "写代码", "status": "in_progress", "activeForm": "正在写代码"], ["content": "测试", "status": "pending", "activeForm": "正在测试"]]
        let updates = translator.translateMessage(assistant([["type": "tool_use", "id": "t1", "name": "TodoWrite", "input": ["todos": todos]]]), forwardSubagentText: false)
        #expect(updates.count == 1)
        #expect(updates[0]["sessionUpdate"]?.stringValue == "plan")
        #expect(updates[0]["entries"]?.arrayValue?[0]["content"]?.stringValue == "正在写代码")
        #expect(updates[0]["entries"]?.arrayValue?[1]["content"]?.stringValue == "测试")
    }

    @Test("TaskCreate 结果登记任务并发出 plan")
    func taskCreatePlan() {
        var translator = makeTranslator()
        let use = assistant([["type": "tool_use", "id": "t1", "name": "TaskCreate", "input": ["subject": "建模", "description": "d"]]])
        #expect(translator.translateMessage(use, forwardSubagentText: false).isEmpty)
        let updates = translator.translateMessage(userResult("t1", "Task #7 created successfully: 建模"), forwardSubagentText: false)
        let plan = updates.first { $0["sessionUpdate"]?.stringValue == "plan" }
        #expect(plan?["entries"]?.arrayValue?.first?["content"]?.stringValue == "建模")
        #expect(translator.taskOrder == ["7"])
    }

    @Test("子 Agent 消息带 parentToolUseId,且默认不转发其文本")
    func subagentStamping() {
        var translator = makeTranslator()
        let blocks: [JSONValue] = [["type": "text", "text": "子代理说话"], ["type": "tool_use", "id": "c1", "name": "Read", "input": ["file_path": "/work/b"]]]
        let updates = translator.translateMessage(assistant(blocks, parent: "task1"), forwardSubagentText: false)
        #expect(updates.count == 1)
        #expect(updates[0]["_meta"]?["claudeCode"]?["parentToolUseId"]?.stringValue == "task1")
        var forwarding = makeTranslator()
        let all = forwarding.translateMessage(assistant(blocks, parent: "task1"), forwardSubagentText: true)
        #expect(all.count == 2)
    }

    @Test("流式入参在顶层逗号处提前细化标题")
    func partialInputRefinement() {
        var translator = makeTranslator()
        _ = translator.translateStreamEvent(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "m"]]])
        _ = translator.translateStreamEvent(["type": "stream_event", "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "t1", "name": "Read", "input": [:]]]])
        var out: [JSONValue] = []
        for piece in ["{\"file_path\":\"/work/x.swift\"", ",\"offset\":", "3}"] {
            out += translator.translateStreamEvent(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": .string(piece)]]])
        }
        let refinements = out.filter { $0["sessionUpdate"]?.stringValue == "tool_call_update" }
        #expect(refinements.count == 1)
        #expect(refinements[0]["rawInput"]?["file_path"]?.stringValue == "/work/x.swift")
    }

    @Test("ExitPlanMode 结果在客户端声明 plan 能力时发 plan_update")
    func exitPlanModeUpdate() {
        var translator = makeTranslator()
        translator.supportsPlan = true
        _ = translator.translateMessage(assistant([["type": "tool_use", "id": "p1", "name": "ExitPlanMode", "input": ["plan": "# 计划\n- 步骤"]]]), forwardSubagentText: false)
        let updates = translator.translateMessage(userResult("p1", "ok"), forwardSubagentText: false)
        #expect(updates.contains { $0["sessionUpdate"]?.stringValue == "plan_update" })
    }

    @Test("Bash 终端能力开启时用 terminal 内容,关闭时用围栏文本")
    func bashTerminalVsConsole() {
        for terminal in [true, false] {
            var translator = makeTranslator(terminal: terminal)
            _ = translator.translateMessage(assistant([["type": "tool_use", "id": "b1", "name": "Bash", "input": ["command": "echo hi"]]]), forwardSubagentText: false)
            let updates = translator.translateMessage(userResult("b1", "hi", structured: ["stdout": "hi", "stderr": "", "interrupted": false]), forwardSubagentText: false)
            let final = updates.last
            #expect(final?["status"]?.stringValue == "completed")
            let types = (final?["content"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue }
            if terminal { #expect(updates.contains { $0["_meta"]?["terminal_output"] != nil } || types.contains("terminal")) }
            else { #expect(!types.contains("terminal")) }
        }
    }
}

@Suite("提示转换")
struct PromptConverterTests {
    @Test("文本、资源链接、内嵌资源与图片")
    func convert() {
        let prompt: [JSONValue] = [
            ["type": "text", "text": "看看这个"],
            ["type": "resource_link", "uri": "file:///work/a.swift", "name": "a"],
            ["type": "resource", "resource": ["uri": "file:///work/b.swift", "text": "let x = 1"]],
            ["type": "image", "data": "AAAA", "mimeType": "image/png"],
        ]
        let content = PromptConverter.convert(prompt)
        #expect(content.count == 5)
        #expect(content[1]["text"]?.stringValue == "[@a.swift](file:///work/a.swift)")
        #expect(content[3]["source"]?["media_type"]?.stringValue == "image/png")
        #expect(content[4]["text"]?.stringValue?.contains("<context ref=\"file:///work/b.swift\">") == true)
    }

    @Test("/mcp:服务:命令 改写为 CLI 识别形式")
    func mcpRewrite() {
        #expect(PromptConverter.rewriteMcpCommand("/mcp:github:review 123") == "/github:review (MCP) 123")
        #expect(PromptConverter.rewriteMcpCommand("/mcp:github:review") == "/github:review (MCP)")
        #expect(PromptConverter.rewriteMcpCommand("/compact") == "/compact")
    }

    @Test("通知:有能力发 notice,无能力降级为粗体文本")
    func notices() {
        #expect(Notices.clientSupports(["session": ["notices": [:]]]))
        #expect(!Notices.clientSupports(["session": [:]]))
        let degraded = Notices.updateOrTranscript(severity: "warning", title: "限额", description: "快用完", supports: false)
        #expect(degraded["content"]?["text"]?.stringValue == "**限额:** 快用完")
        let native = Notices.updateOrTranscript(severity: "warning", title: "限额", description: nil, supports: true)
        #expect(native["sessionUpdate"]?.stringValue == "notice")
        let split = Notices.split("**标题**\n正文", fallbackTitle: "x")
        #expect(split.title == "标题")
        #expect(split.description == "正文")
    }
}
