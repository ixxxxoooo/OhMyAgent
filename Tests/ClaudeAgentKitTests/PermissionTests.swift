// @author ixxxxoooo
// 权限与征询的纯函数测试:变更集校验、选项构建、响应解码、AskUserQuestion 编解码、拒绝回退。

import ACPKit
import Foundation
import Testing
@testable import ClaudeAgentKit

private func addRule(_ tool: String, _ content: String?, destination: String = "localSettings") -> JSONValue {
    var rule: [String: JSONValue] = ["toolName": .string(tool)]
    if let content { rule["ruleContent"] = .string(content) }
    return ["type": "addRules", "rules": [.object(rule)], "behavior": "allow", "destination": .string(destination)]
}

private func context(_ tool: String, input: JSONValue = .object([:]), suggestions: [JSONValue]? = nil, forcedAsk: Bool = false, modes: [String] = [], prePlan: String? = nil, persistent: Bool = true) -> PermissionOptionContext {
    PermissionOptionContext(
        toolName: tool, displayName: nil, input: input, cwd: "/work/proj",
        durableChangeSet: DurableChangeSet.normalize(suggestions.map { .array($0) }, forcedAsk: forcedAsk),
        allowPersistentOptions: persistent, availableModes: modes, prePlanMode: prePlan, contextUsedPercent: 42
    )
}

@Suite("权限选项")
struct PermissionOptionTests {
    @Test("变更集校验:非法规则、目的地、过多更新一律丢弃")
    func normalization() {
        #expect(DurableChangeSet.normalize([addRule("Bash", "ls:*")]) != nil)
        #expect(DurableChangeSet.normalize([addRule("Bash", "ls:*")], forcedAsk: true) == nil)
        #expect(DurableChangeSet.normalize(.array([])) == nil)
        #expect(DurableChangeSet.normalize(nil) == nil)
        #expect(DurableChangeSet.normalize([addRule("Bash", "ls", destination: "nowhere")]) == nil)
        #expect(DurableChangeSet.normalize([["type": "setMode", "mode": "weird", "destination": "session"]]) == nil)
        #expect(DurableChangeSet.normalize([addRule("Bash", "bad\u{07}rule")]) == nil)
        #expect(DurableChangeSet.normalize(.array(Array(repeating: addRule("Bash", "ls"), count: 101))) == nil)
        #expect(DurableChangeSet.normalize([["type": "addDirectories", "directories": ["/a"], "destination": "session"]]) != nil)
    }

    @Test("Bash:有建议时多出「不再询问」选项,文案按命令生成")
    func bash() {
        let withSuggestion = PermissionOptionBuilder.build(context("Bash", suggestions: [addRule("Bash", "git status:*")]))
        #expect(withSuggestion.map(\.optionId) == ["allow-once", "allow-with-updates", "reject"])
        #expect(withSuggestion[1].name == "Yes, and don't ask again for git status commands")
        let plain = PermissionOptionBuilder.build(context("Bash"))
        #expect(plain.map(\.optionId) == ["allow-once", "reject"])
        #expect(plain.map(\.kind) == ["allow_once", "reject_once"])
    }

    @Test("文件读写:会话级建议给出对应文案")
    func fileLabels() {
        let readRule: JSONValue = ["type": "addRules", "rules": [["toolName": "Read"]], "behavior": "allow", "destination": "session"]
        let read = PermissionOptionBuilder.build(context("Read", input: ["file_path": "/work/proj/a.swift"], suggestions: [readRule]))
        #expect(read.last?.optionId == "reject")
        #expect(read.contains { $0.name == "Yes, during this session" })
        let acceptEdits: JSONValue = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
        let edit = PermissionOptionBuilder.build(context("Edit", input: ["file_path": "/work/proj/a.swift"], suggestions: [acceptEdits]))
        #expect(edit.contains { $0.name == "Yes, allow all edits during this session" })
        let outside = PermissionOptionBuilder.build(context("Edit", input: ["file_path": "/elsewhere/dir/a.swift"], suggestions: [acceptEdits]))
        #expect(outside.contains { $0.name == "Yes, allow all edits in dir/ during this session" })
    }

    @Test("WebFetch / Skill / EnterPlanMode")
    func webSkillPlan() {
        let fetch = PermissionOptionBuilder.build(context("WebFetch", input: ["url": "https://example.com/a"]))
        #expect(fetch[1].name == "Yes, and don't ask again for example.com")
        let noPersist = PermissionOptionBuilder.build(context("WebFetch", input: ["url": "https://example.com/a"], persistent: false))
        #expect(noPersist.map(\.optionId) == ["allow-once", "reject"])
        let skill = PermissionOptionBuilder.build(context("Skill", input: ["skill": "pdf extract"]))
        #expect(skill.map(\.optionId) == ["allow-once", "allow-skill-exact", "allow-skill-prefix", "reject"])
        #expect(skill[2].name == "Yes, and don't ask again for pdf:* commands")
        let enter = PermissionOptionBuilder.build(context("EnterPlanMode"))
        #expect(enter.map(\.name) == ["Yes, enter plan mode", "No, start implementing now"])
    }

    @Test("ExitPlanMode:按可用模式与计划内容给出选项")
    func exitPlan() {
        let full = PermissionOptionBuilder.build(context("ExitPlanMode", input: ["plan": "步骤"], modes: ["default", "auto", "bypassPermissions"]))
        #expect(full.map(\.optionId) == ["exit-plan-default", "exit-plan-clear-auto", "exit-plan-auto", "exit-plan-bypass", "reject"])
        #expect(full[1].name == "Yes, clear context (42% used) and use auto mode")
        let bypassFirst = PermissionOptionBuilder.build(context("ExitPlanMode", input: ["plan": "步骤"], modes: ["auto", "bypassPermissions"], prePlan: "bypassPermissions"))
        #expect(bypassFirst[1].optionId == "exit-plan-clear-bypass")
        let minimal = PermissionOptionBuilder.build(context("ExitPlanMode", input: [:], modes: ["default"]))
        #expect(minimal.map(\.optionId).contains("exit-plan-accept-edits"))
        #expect(!minimal.map(\.optionId).contains { $0.hasPrefix("exit-plan-clear") })
    }

    @Test("MCP 工具与兜底工具")
    func mcpAndFallback() {
        let rule = addRule("mcp__fs__read", nil)
        let mcp = PermissionOptionBuilder.build(context("mcp__fs__read", suggestions: [rule]))
        #expect(mcp[1].name == "Yes, and don't ask again for mcp__fs__read commands")
        let fallback = PermissionOptionBuilder.build(context("WebSearch"))
        #expect(fallback[1].optionId == "allow-with-updates")
    }

    @Test("defaultToNo 把拒绝排在最前")
    func declineFirst() {
        var ctx = context("Bash", suggestions: [addRule("Bash", "ls:*")])
        ctx.defaultToNo = true
        #expect(PermissionOptionBuilder.build(ctx).first?.optionId == "reject")
    }
}

@Suite("权限响应解码")
struct PermissionDecoderTests {
    private func selected(_ id: String) -> JSONValue { ["outcome": ["outcome": "selected", "optionId": .string(id)]] }

    @Test("允许一次与拒绝")
    func allowOnceAndReject() throws {
        let input: JSONValue = ["command": "ls"]
        let offered = PermissionOptionBuilder.build(context("Bash", input: input))
        let allow = try PermissionDecoder.decode(response: selected("allow-once"), toolName: "Bash", input: input, toolUseID: "t", offered: offered, durable: nil)
        #expect(allow.result["behavior"]?.stringValue == "allow")
        #expect(allow.result["toolUseID"]?.stringValue == "t")
        #expect(allow.result["decisionClassification"]?.stringValue == "user_temporary")
        let deny = try PermissionDecoder.decode(response: selected("reject"), toolName: "Bash", input: input, toolUseID: "t", offered: offered, durable: nil)
        #expect(deny.result["behavior"]?.stringValue == "deny")
        #expect(deny.result["decisionClassification"]?.stringValue == "user_reject")
    }

    @Test("始终允许写入持久更新;取消与未提供的选项抛错")
    func durableAndErrors() throws {
        let suggestions = [addRule("Bash", "ls:*")]
        let durable = DurableChangeSet.normalize(.array(suggestions))
        let offered = PermissionOptionBuilder.build(context("Bash", suggestions: suggestions))
        let always = try PermissionDecoder.decode(response: selected("allow-with-updates"), toolName: "Bash", input: [:], toolUseID: nil, offered: offered, durable: durable)
        #expect(always.updatedPermissions == suggestions)
        #expect(always.result["decisionClassification"]?.stringValue == "user_permanent")
        #expect(throws: PermissionError.aborted) {
            try PermissionDecoder.decode(response: ["outcome": ["outcome": "cancelled"]], toolName: "Bash", input: [:], toolUseID: nil, offered: offered, durable: durable)
        }
        #expect(throws: PermissionError.self) {
            try PermissionDecoder.decode(response: selected("exit-plan-auto"), toolName: "Bash", input: [:], toolUseID: nil, offered: offered, durable: durable)
        }
    }

    @Test("ExitPlanMode:切模式、保持规划、清空上下文")
    func exitPlan() throws {
        let offered = PermissionOptionBuilder.build(context("ExitPlanMode", input: ["plan": "p"], modes: ["auto", "bypassPermissions"]))
        let input: JSONValue = ["plan": "p"]
        let auto = try PermissionDecoder.decode(response: selected("exit-plan-auto"), toolName: "ExitPlanMode", input: input, toolUseID: "t", offered: offered, durable: nil)
        #expect(auto.updatedPermissions.first?["mode"]?.stringValue == "auto")
        let keep = try PermissionDecoder.decode(response: selected("reject"), toolName: "ExitPlanMode", input: input, toolUseID: "t", offered: offered, durable: nil)
        #expect(keep.result["interrupt"]?.boolValue == true)
        let clear = try PermissionDecoder.decode(response: selected("exit-plan-clear-auto"), toolName: "ExitPlanMode", input: input, toolUseID: "t", offered: offered, durable: nil)
        #expect(clear.contextResetMode == "auto")
        #expect(clear.result["behavior"]?.stringValue == "deny")
        #expect(clear.result["interrupt"]?.boolValue == true)
    }

    @Test("Skill 与 WebFetch 生成本地允许规则")
    func generatedRules() throws {
        let skillOffered = PermissionOptionBuilder.build(context("Skill", input: ["skill": "pdf extract"]))
        let exact = try PermissionDecoder.decode(response: selected("allow-skill-exact"), toolName: "Skill", input: ["skill": "pdf extract"], toolUseID: nil, offered: skillOffered, durable: nil)
        #expect(exact.updatedPermissions.first?.at("rules")?.arrayValue?.first?["ruleContent"]?.stringValue == "pdf extract")
        let prefix = try PermissionDecoder.decode(response: selected("allow-skill-prefix"), toolName: "Skill", input: ["skill": "pdf extract"], toolUseID: nil, offered: skillOffered, durable: nil)
        #expect(prefix.updatedPermissions.first?.at("rules")?.arrayValue?.first?["ruleContent"]?.stringValue == "pdf:*")
        let fetchInput: JSONValue = ["url": "https://example.com/x"]
        let fetchOffered = PermissionOptionBuilder.build(context("WebFetch", input: fetchInput))
        let fetch = try PermissionDecoder.decode(response: selected("allow-with-updates"), toolName: "WebFetch", input: fetchInput, toolUseID: nil, offered: fetchOffered, durable: nil)
        #expect(fetch.updatedPermissions.first?.at("rules")?.arrayValue?.first?["ruleContent"]?.stringValue == "domain:example.com")
        let otherOffered = PermissionOptionBuilder.build(context("WebSearch"))
        let other = try PermissionDecoder.decode(response: selected("allow-with-updates"), toolName: "WebSearch", input: [:], toolUseID: nil, offered: otherOffered, durable: nil)
        #expect(other.updatedPermissions.first?.at("rules")?.arrayValue?.first?["toolName"]?.stringValue == "WebSearch")
    }
}

@Suite("征询编解码")
struct ElicitationTests {
    private let input: JSONValue = ["questions": [
        ["question": "选框架?", "header": "框架", "multiSelect": false, "options": [["label": "SwiftUI", "description": "声明式"], ["label": "AppKit"]]],
        ["question": "选平台?", "multiSelect": true, "options": [["label": "macOS"], ["label": "iOS"]]],
    ]]

    @Test("问题抽取:丢弃缺选项的问题")
    func extract() {
        #expect(Elicitation.questions(from: input)?.count == 2)
        #expect(Elicitation.questions(from: ["questions": [["question": "x", "options": []]]]) == nil)
        #expect(Elicitation.questions(from: .object([:])) == nil)
    }

    @Test("请求结构:单题用题干作 message,多题加 description 与自定义字段")
    func request() throws {
        let questions = try #require(Elicitation.questions(from: input))
        let multi = Elicitation.createRequest(questions, sessionId: "s", toolCallId: "t")
        #expect(multi["message"]?.stringValue == "Please answer the following questions.")
        let properties = try #require(multi.at("requestedSchema", "properties")?.objectValue)
        #expect(properties["question_0"]?["oneOf"]?.arrayValue?.count == 2)
        #expect(properties["question_0"]?["description"]?.stringValue == "选框架?")
        #expect(properties["question_1"]?["items"]?["anyOf"]?.arrayValue?.count == 2)
        #expect(properties["question_1_custom"]?["title"]?.stringValue == "Other")
        let single = Elicitation.createRequest([questions[0]], sessionId: "s", toolCallId: nil)
        #expect(single["message"]?.stringValue == "选框架?")
        #expect(single.at("requestedSchema", "properties", "question_0", "description") == nil)
        #expect(single["toolCallId"] == nil)
    }

    @Test("应用答案:单选、多选(含逗号加引号)、自定义补充、拒绝与取消")
    func answers() throws {
        let questions = try #require(Elicitation.questions(from: input))
        let accepted = Elicitation.applyAnswer(["action": "accept", "content": ["question_0": "SwiftUI", "question_0_custom": "要快", "question_1": ["macOS", "i, OS"]]], input: input, questions: questions)
        #expect(accepted?.at("answers", "选框架?")?.stringValue == "SwiftUI")
        #expect(accepted?.at("annotations", "选框架?", "notes")?.stringValue == "要快")
        #expect(accepted?.at("answers", "选平台?")?.stringValue == #"macOS, "i, OS""#)
        let onlyCustom = Elicitation.applyAnswer(["action": "accept", "content": ["question_0_custom": "都不选"]], input: input, questions: questions)
        #expect(onlyCustom?.at("answers", "选框架?")?.stringValue == "都不选")
        let declined = Elicitation.applyAnswer(["action": "decline"], input: input, questions: questions)
        #expect(declined?["answers"]?.objectValue?.isEmpty == true)
        #expect(Elicitation.applyAnswer(["action": "cancel"], input: input, questions: questions) == nil)
    }

    @Test("MCP 征询与拒绝回退")
    func mcpAndRefusal() throws {
        let form = try #require(Elicitation.mcpRequest(["mode": "form", "message": "填写", "requestedSchema": ["properties": ["a": ["type": "string"]]]], sessionId: "s"))
        #expect(form["requestedSchema"]?["type"]?.stringValue == "object")
        let url = try #require(Elicitation.mcpRequest(["mode": "url", "message": "授权", "url": "https://x/auth"], sessionId: "s"))
        #expect(url["elicitationId"]?.stringValue?.isEmpty == false)
        #expect(Elicitation.mcpRequest(["mode": "url", "message": "无地址"], sessionId: "s") == nil)
        #expect(Elicitation.mcpResult(["action": "accept", "content": ["a": "b"]])["content"]?["a"]?.stringValue == "b")
        #expect(Elicitation.mcpResult(["action": "decline"])["action"]?.stringValue == "decline")
        #expect(Elicitation.mcpResult(["action": "whatever"])["action"]?.stringValue == "cancel")
        let refusal = try #require(Elicitation.refusalRequest(payload: ["originalModel": "A", "fallbackModel": "B", "apiRefusalCategory": "cyber"], sessionId: "s"))
        #expect(refusal["message"]?.stringValue == "A declined this request (cyber). Retry with B?")
        #expect(Elicitation.refusalRequest(payload: ["originalModel": "A"], sessionId: "s") == nil)
        #expect(Elicitation.refusalResult(["action": "accept", "content": ["choice": "retry_fallback"]]) == "retry_fallback")
        #expect(Elicitation.refusalResult(["action": "decline"]) == "cancelled")
    }
}
