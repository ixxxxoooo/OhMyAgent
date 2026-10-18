// @author ixxxxoooo
// Bridge 工具 ask_user_question:入参 → elicitation 表单、回答 → 文本,以及 OpenCode 启动覆盖。

import ACPKit
import Foundation
import Testing

@testable import AgentHost
@testable import ChatKit

@MainActor
@Suite("ask_user_question 跨引擎提问")
struct AskBridgeTests {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    @Test("入参转成 question_N 表单,单题把题干放进 message,向导能解析")
    func paramsParse() throws {
        let args = try json(#"{"questions":[{"question":"选哪个?","header":"测试","options":[{"label":"A"},{"label":"B","description":"b"}]}]}"#)
        let params = try #require(SessionBridge.elicitationParams(from: args))
        #expect(params["message"]?.stringValue == "选哪个?")
        let fields = ElicitationParser.fields(from: params)
        #expect(fields.map(\.id) == ["question_0", "question_0_custom"])
        #expect(fields[0].title == "测试")
    }

    @Test("非法入参返回 nil")
    func invalid() throws {
        #expect(SessionBridge.elicitationParams(from: try json(#"{"questions":[]}"#)) == nil)
        #expect(SessionBridge.elicitationParams(from: try json(#"{"questions":[{"question":"q","options":[{"label":"A"}]}]}"#)) == nil)
    }

    @Test("回答与取消的文本")
    func answers() throws {
        let questions = try json(#"[{"question":"选哪个?"}]"#).arrayValue ?? []
        let ok = SessionBridge.answerResult(response: try json(#"{"action":"accept","content":{"question_0":"A"}}"#), questions: questions)
        #expect(!ok.isError && ok.text.contains(#""选哪个?"="A""#))
        let no = SessionBridge.answerResult(response: try json(#"{"action":"cancel"}"#), questions: questions)
        #expect(no.isError)
    }

    @Test("OpenCode ACP 启动时禁用自带 question;用户自设配置不覆盖;其他 Agent 不受影响")
    func openCodeOverride() {
        var env: [String: String] = [:]
        GenericACPProvider.applyOpenCodeOverrides(&env, executable: "/opt/homebrew/bin/opencode", arguments: ["acp"])
        #expect(env["OPENCODE_CONFIG_CONTENT"]?.contains("question") == true)
        var custom = ["OPENCODE_CONFIG_CONTENT": "{}"]
        GenericACPProvider.applyOpenCodeOverrides(&custom, executable: "opencode", arguments: ["acp"])
        #expect(custom["OPENCODE_CONFIG_CONTENT"] == "{}")
        var other: [String: String] = [:]
        GenericACPProvider.applyOpenCodeOverrides(&other, executable: "codex", arguments: ["acp"])
        #expect(other.isEmpty)
    }
}
