// @author ixxxxoooo
// Google Antigravity(agy_acp_server 1.4)工具调用协议适配测试:
// 载荷取自真实抓包——历史回放里 rawInput 是 JSON 字符串、实时流里键名是 snake_case、结果在 rawOutput 里。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@MainActor
@Suite("Antigravity 工具适配")
struct AntigravityToolTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test("回放:rawInput 为 JSON 字符串时解析为对象并补齐规范键")
    func replayStringInput() throws {
        let raw = try json(#"""
        {"toolCallId":"c1","title":"git status","kind":"execute","status":"completed",
         "rawInput":"{\"CommandLine\":\"git status\",\"Cwd\":\"/p\",\"WaitMsBeforeAsync\":5000}"}
        """#)
        let call = ToolCall(json: raw)
        #expect(call.rawInput?["command"]?.stringValue == "git status")
        #expect(call.rawInput?["cwd"]?.stringValue == "/p")
        let presentation = ToolPresentation(tool: call)
        #expect(presentation.category == .terminal)
        #expect(presentation.subject == "git status")
    }

    @Test("实时流:snake_case 键与浮点行号")
    func liveSnakeCaseInput() throws {
        let raw = try json(#"""
        {"toolCallId":"c2","title":"Running client_view_file","kind":"read","status":"in_progress",
         "locations":[{"path":"/p/Package.swift"}],
         "rawInput":{"absolute_path":"/p/Package.swift","end_line":5.0,"start_line":1.0}}
        """#)
        let call = ToolCall(json: raw)
        #expect(call.name == "client_view_file")
        let presentation = ToolPresentation(tool: call)
        #expect(presentation.category == .read)
        #expect(presentation.subject == "/p/Package.swift")
        #expect(presentation.subjectIsPath)
        #expect(presentation.detail == "L1-5")
    }

    @Test("编辑与新建:Diff 回退字段与写入判定")
    func editAndCreate() throws {
        let edit = ToolCall(json: try json(#"""
        {"toolCallId":"c3","title":"Running replace_file_content","kind":"edit","status":"completed",
         "content":[{"path":"/p/A.swift","oldText":"a","newText":"b","type":"diff"}],
         "rawInput":"{\"TargetFile\":\"/p/A.swift\",\"TargetContent\":\"a\",\"ReplacementContent\":\"b\",\"StartLine\":3,\"EndLine\":4}"}
        """#))
        #expect(edit.rawInput?["old_string"]?.stringValue == "a")
        #expect(edit.rawInput?["new_string"]?.stringValue == "b")
        let editPresentation = ToolPresentation(tool: edit)
        #expect(editPresentation.category == .edit)
        #expect(editPresentation.detail == "L3-4")

        let create = ToolCall(json: try json(#"""
        {"toolCallId":"c4","title":"Run client_create_file?","kind":"edit","status":"pending",
         "rawInput":{"code_content":"hello","target_file":"/p/new.txt"}}
        """#))
        #expect(ToolPresentation(tool: create).category == .write)
        #expect(ToolPresentation.diffStats(of: create)?.added == 1)
    }

    @Test("增量更新:rawInput 按键合并,不丢已有字段")
    func updateMergesInput() throws {
        var call = ToolCall(json: try json(#"""
        {"toolCallId":"c5","title":"echo hi","kind":"execute","status":"pending",
         "rawInput":{"CommandLine":"echo hi","Cwd":"/p","RunPersistent":false}}
        """#))
        call.apply(update: try json(#"""
        {"toolCallId":"c5","status":"in_progress","rawInput":{"command_line":"echo hi","working_dir":"/p"}}
        """#))
        #expect(call.status == .inProgress)
        #expect(call.rawInput?["command"]?.stringValue == "echo hi")
        #expect(call.rawInput?["RunPersistent"]?.boolValue == false)
    }

    @Test("终端结果:rawOutput.combinedOutput 与退出码")
    func terminalResult() throws {
        var call = ToolCall(json: try json(#"""
        {"toolCallId":"c6","title":"ls","kind":"execute","status":"pending","rawInput":{"CommandLine":"ls"}}
        """#))
        call.apply(update: try json(#"""
        {"toolCallId":"c6","status":"completed",
         "rawOutput":{"exitCode":2,"exit_code":2,"combinedOutput":"ls: x: No such file\r\n","formatted_output":"ls: x: No such file\r\n"}}
        """#))
        #expect(call.status == .completed)
        #expect(call.resultText == "ls: x: No such file\r\n")
        #expect(call.exitCode == 2)
        #expect(call.failureText == nil)   // 只有失败状态才有失败原因
    }

    @Test("失败原因:rawOutput 是纯文本错误时可取出")
    func failureText() throws {
        var call = ToolCall(json: try json(#"""
        {"toolCallId":"c7","title":"Running view_file","kind":"read","status":"pending",
         "rawInput":{"AbsolutePath":"/x/agents.json"}}
        """#))
        call.apply(update: try json(#"""
        {"toolCallId":"c7","status":"failed","rawOutput":"Access to path \"/x/agents.json\" is denied."}
        """#))
        #expect(call.status == .failed)
        #expect(call.failureText?.contains("denied") == true)
    }

    @Test("读取成功时 rawOutput 为空串:不产生结果文本")
    func emptyReadOutput() throws {
        var call = ToolCall(json: try json(#"""
        {"toolCallId":"c8","title":"Running view_file","kind":"read","status":"completed","rawInput":{"AbsolutePath":"/x"}}
        """#))
        call.apply(update: try json(#"{"toolCallId":"c8","status":"completed","rawOutput":""}"#))
        #expect(call.resultText == nil)
        #expect(call.failureText == nil)
    }

    @Test("带结果但无显式状态的更新视为完成;显式 in_progress 不被覆盖")
    func statusFromOutput() throws {
        var call = ToolCall(toolCallId: "c9", kind: .execute, status: .inProgress)
        call.apply(update: try json(#"{"toolCallId":"c9","rawOutput":{"combinedOutput":"x"}}"#))
        #expect(call.status == .completed)
        var running = ToolCall(toolCallId: "c10", kind: .execute, status: .pending)
        running.apply(update: try json(#"{"toolCallId":"c10","status":"in_progress","rawOutput":{"combinedOutput":"partial"}}"#))
        #expect(running.status == .inProgress)
    }

    @Test("轮次收尾:未终结工具正常结束标记完成,取消标记失败")
    func finishTurnStatuses() throws {
        let store = TimelineStore()
        store.apply(.toolCall(ToolCall(toolCallId: "t1", kind: .read, status: .inProgress)))
        store.finishTurn()
        #expect(store.entries.last?.tool?.status == .completed)

        let aborted = TimelineStore()
        aborted.apply(.toolCall(ToolCall(toolCallId: "t2", kind: .execute, status: .inProgress)))
        aborted.finishTurn(aborted: true)
        #expect(aborted.entries.last?.tool?.status == .failed)
    }

    @Test("美化只有工具标识的标题")
    func prettyTitle() {
        #expect(ToolPresentation.prettyTitle("Running manage_task") == "manage task")
        #expect(ToolPresentation.prettyTitle("Running ls -la") == "Running ls -la")
        #expect(ToolInputNormalizer.toolName(fromTitle: "Run client_create_file?") == "client_create_file")
        #expect(ToolInputNormalizer.toolName(fromTitle: "git status") == nil)
    }
}
