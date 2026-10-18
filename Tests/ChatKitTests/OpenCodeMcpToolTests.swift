// @author ixxxxoooo
// MCP 工具身份在 Claude Code(mcp__服务器__工具)与 OpenCode(execute 包裹 JS 代码)两种形态下的识别;
// 载荷取自 `opencode acp` 实测。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@MainActor
@Suite("MCP 工具跨引擎识别")
struct OpenCodeMcpToolTests {
    private func call(_ text: String) throws -> ToolCall {
        ToolCall(json: try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
    }

    @Test("Claude Code:mcp__server__tool")
    func claudeStyle() throws {
        let tool = try call(#"{"toolCallId":"a","name":"mcp__ohmyagent__canvas_create","title":"x","status":"completed","rawInput":{"title":"T"}}"#)
        #expect(tool.mcpName == "mcp__ohmyagent__canvas_create")
        #expect(tool.mcpInput?["title"]?.stringValue == "T")
        let p = ToolPresentation(tool: tool)
        #expect(p.category == .mcp && p.mcpServer == "ohmyagent" && p.verb == "canvas_create")
    }

    @Test("OpenCode:运行中只有代码,按 tools.server.tool( 解析")
    func openCodeRunning() throws {
        let tool = try call(#"{"toolCallId":"b","title":"execute","status":"in_progress","rawInput":{"code":"return tools.ohmyagent.canvas_create({title: \"探针\", blocks: []})"}}"#)
        #expect(tool.mcpName == "mcp__ohmyagent__canvas_create")
        #expect(ToolPresentation(tool: tool).category == .mcp)
    }

    @Test("OpenCode:完成后取结果元数据里的权威清单与入参,画布卡片可还原")
    func openCodeCompleted() throws {
        let tool = try call(#"""
        {"toolCallId":"c","title":"execute","status":"completed","rawInput":{"code":"return await tools[\"ohmyagent\"][\"canvas_create\"]({})"},
         "content":[{"type":"content","content":{"type":"text","text":"Canvas created. canvas_id: probe-canvas-1\ntitle: Probe"}}],
         "rawOutput":{"metadata":{"toolCalls":[{"tool":"ohmyagent.canvas_create","status":"completed","input":{"title":"探针","blocks":[]}}]}}}
        """#)
        #expect(tool.mcpRef == McpToolRef(server: "ohmyagent", tool: "canvas_create", input: tool.mcpRef?.input))
        let ref = CanvasToolRef.of(tool)
        #expect(ref?.canvasID == "probe-canvas-1")
        #expect(ref?.title == "探针")
        #expect(ref?.isUpdate == false)
    }

    @Test("非 MCP 的 execute(调用内置工具)不算 MCP;一次调用多个 MCP 工具时合并显示")
    func nonMcpAndMulti() throws {
        let plain = try call(#"{"toolCallId":"d","title":"execute","status":"completed","rawInput":{"code":"return tools[\"glob\"]({pattern:\"*\"})"}}"#)
        #expect(plain.mcpRef == nil)
        let multi = try call(#"{"toolCallId":"e","title":"execute","status":"completed","rawInput":{"code":"await tools.a.x(); await tools.b.y();"}}"#)
        #expect(multi.mcpRefs.count == 2)
        #expect(ToolPresentation(tool: multi).verb == "x +1")
    }
}
