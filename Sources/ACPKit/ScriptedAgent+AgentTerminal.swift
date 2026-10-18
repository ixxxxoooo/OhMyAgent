// @author ixxxxoooo
// 脚本化 Agent 的终端场景:模拟真实适配器经 `_meta.terminal_*` 报告 Bash 的前台与后台命令,
// 用于在没有真实 Claude Code 的情况下演示「Agent 终端」。

import Foundation

extension ScriptedAgent {
    /// 以 `_meta` 报告一条 Bash 工具调用。
    /// - Parameters:
    ///   - tool: 场景里的工具
    ///   - terminal: 终端描述(前台/后台)
    ///   - ctx: 场景上下文
    ///   - parent: 父工具调用(子 Agent 内部时)
    func runMetaTerminalTool(_ tool: ScenarioTool, terminal: ScenarioTerminal, ctx: ScenarioContext, parent: String?) async {
        let sessionId = ctx.sessionId
        let toolId = ctx.scoped(tool.id)
        let terminalContent: JSONValue = .array([["type": "terminal", "terminalId": .string(toolId)]])
        await emit(sessionId, parent: parent, [
            "sessionUpdate": "tool_call", "toolCallId": .string(toolId), "title": .string(tool.title), "kind": .string(tool.kind),
            "name": .string(tool.name), "status": "in_progress", "rawInput": tool.input, "locations": tool.locations,
            "content": terminalContent, "_meta": ["terminal_info": ["terminal_id": .string(toolId)]],
        ])
        await pause(sessionId)
        if tool.holdMillis > 0 { await scaledDelay(tool.holdMillis) }
        guard !terminal.backgroundLines.isEmpty else {
            let failed = tool.finish == .failed
            await emit(sessionId, parent: parent, [
                "sessionUpdate": "tool_call_update", "toolCallId": .string(toolId), "status": failed ? "failed" : "completed",
                "content": terminalContent,
                "_meta": [
                    "terminal_info": ["terminal_id": .string(toolId)],
                    "terminal_output": ["terminal_id": .string(toolId), "data": .string(tool.output ?? "")],
                    "terminal_exit": ["terminal_id": .string(toolId), "exit_code": failed ? 1 : .int(terminal.exitCode ?? 0), "signal": nil],
                ],
            ])
            await pause(sessionId)
            return
        }
        // 后台命令:真实适配器此时只报告「已转入后台」和输出文件路径,输出写在文件里
        let path = NSTemporaryDirectory() + "oma-demo-bg-\(UUID().uuidString).output"
        FileManager.default.createFile(atPath: path, contents: Data())
        let notice = "Command running in background with ID: \(toolId). Output is being written to: \(path)"
        await emit(sessionId, parent: parent, [
            "sessionUpdate": "tool_call_update", "toolCallId": .string(toolId), "status": "completed",
            "content": terminalContent,
            "_meta": [
                "terminal_info": ["terminal_id": .string(toolId)],
                "terminal_output": ["terminal_id": .string(toolId), "data": .string(notice)],
            ],
        ])
        await pause(sessionId)
        Task { [self] in
            for line in terminal.backgroundLines {
                await scaledDelay(terminal.lineIntervalMillis)
                if let handle = FileHandle(forWritingAtPath: path) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data((line + "\n").utf8))
                    try? handle.close()
                }
            }
            await scaledDelay(terminal.lineIntervalMillis)
            await emit(sessionId, parent: parent, [
                "sessionUpdate": "tool_call_update", "toolCallId": .string(toolId),
                "_meta": ["terminal_exit": ["terminal_id": .string(toolId), "exit_code": nil, "signal": nil]],
            ])
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
