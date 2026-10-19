// @author ixxxxoooo
// 适配器 `_meta.terminal_*` 事件解析与后台命令输出路径解析。

import Foundation
import Testing
@testable import ACPKit

@Suite("工具终端事件")
struct ToolTerminalEventTests {
    @Test("tool_call 只带 terminal_info:终端开始")
    func started() {
        let event = ToolTerminalEvent.parse(["terminal_info": ["terminal_id": "t1"]])
        #expect(event?.terminalId == "t1")
        #expect(event?.started == true && event?.finished == false && event?.output == nil)
    }

    @Test("结果更新:输出与退出码一起到达")
    func outputAndExit() {
        let meta: JSONValue = [
            "terminal_info": ["terminal_id": "t1"],
            "terminal_output": ["terminal_id": "t1", "data": "hello\n"],
            "terminal_exit": ["terminal_id": "t1", "exit_code": 2, "signal": nil],
        ]
        let event = ToolTerminalEvent.parse(meta)
        #expect(event?.output == "hello\n" && event?.outputIsDelta == false)
        #expect(event?.finished == true && event?.exitCode == 2 && event?.signal == nil)
    }

    @Test("增量模式与退出码未知(后台任务结束)")
    func deltaAndUnknownExit() {
        let delta = ToolTerminalEvent.parse(["terminal_output_delta": ["terminal_id": "t2", "data": "x"]])
        #expect(delta?.outputIsDelta == true && delta?.output == "x")
        let ended = ToolTerminalEvent.parse(["terminal_exit": ["terminal_id": "t2", "exit_code": nil, "signal": nil]])
        #expect(ended?.finished == true && ended?.exitCode == nil)
    }

    @Test("没有终端字段或缺少终端标识时返回 nil")
    func invalid() {
        #expect(ToolTerminalEvent.parse(nil) == nil)
        #expect(ToolTerminalEvent.parse(["claudeCode": ["toolName": "Bash"]]) == nil)
        #expect(ToolTerminalEvent.parse(["terminal_output": ["data": "orphan"]]) == nil)
    }

    @Test("首个 tool_call 的 terminal_info 解析进 ToolCall")
    func toolCallCarriesEvent() {
        let call = ToolCall(json: ["toolCallId": "c1", "title": "Run", "kind": "execute", "_meta": ["terminal_info": ["terminal_id": "c1"]]])
        #expect(call.terminalEvent?.terminalId == "c1" && call.terminalEvent?.started == true)
    }

    @Test("后台命令结果文字里取出输出文件路径")
    func backgroundPath() {
        let text = "Command running in background with ID: bk7. Output is being written to: /private/tmp/claude-501/-Users-x-proj/abc/tasks/bk7.output"
        #expect(ToolTerminalEvent.backgroundOutputPath(in: text) == "/private/tmp/claude-501/-Users-x-proj/abc/tasks/bk7.output")
        let trailing = "Command running in background with ID: bk7. Output is being written to: /tmp/a/bk7.log."
        #expect(ToolTerminalEvent.backgroundOutputPath(in: trailing) == "/tmp/a/bk7.log")
        let moved = "Command was moved to the background (ID: b6tugu3ij) so that a message that arrived while it was running can reach you; it was not interrupted. Output is being written to: /private/tmp/claude-501/-Users-x/bb46/tasks/b6tugu3ij.output. You will be notified when it completes."
        #expect(ToolTerminalEvent.backgroundOutputPath(in: moved) == "/private/tmp/claude-501/-Users-x/bb46/tasks/b6tugu3ij.output")
        #expect(ToolTerminalEvent.backgroundOutputPath(in: "hello world") == nil)
        #expect(ToolTerminalEvent.backgroundOutputPath(in: "Output is being written to: /tmp/x.output") == nil, "不是后台命令的结果文字不识别")
    }
}
