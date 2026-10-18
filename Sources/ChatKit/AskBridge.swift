// @author ixxxxoooo
// Bridge 工具 ask_user_question:任何 ACP 引擎都能用的提问(OpenCode 的 ACP 模式不会转发自带 question 工具)。
// 入参转成与 Claude Code 的 AskUserQuestion 相同的 `elicitation/create` 表单,复用提问向导与回答摘要。

import ACPKit
import AgentHost
import Foundation

extension SessionBridge {
    /// `ask_user_question`:弹出提问向导并等待回答。
    /// - Parameter arguments: MCP 入参 `{questions:[{question, header?, options:[{label, description?}], multiSelect?}]}`
    /// - Returns: 回答文本;用户取消/跳过时为错误结果
    func callAskUserQuestion(arguments: JSONValue) async -> BridgeResult {
        guard let params = Self.elicitationParams(from: arguments) else {
            return BridgeResult("questions 必须是 1-4 道题,每题含 question 与至少 2 个 options(label)", isError: true)
        }
        guard let model = await MainActor.run(body: { self.model }) else { return BridgeResult("会话已关闭", isError: true) }
        let response = await model.awaitElicitation(method: "elicitation/create", params: params)
        return Self.answerResult(response: response, questions: arguments["questions"]?.arrayValue ?? [])
    }

    /// 把工具入参转成 `elicitation/create` 参数(`question_N` / `question_N_custom` 字段)。
    /// - Parameter arguments: 工具入参
    /// - Returns: 参数;入参不合法返回 nil
    static func elicitationParams(from arguments: JSONValue) -> JSONValue? {
        guard let questions = arguments["questions"]?.arrayValue, (1...4).contains(questions.count) else { return nil }
        var properties: [String: JSONValue] = [:]
        for (index, item) in questions.enumerated() {
            guard let prompt = item["question"]?.stringValue, !prompt.isEmpty,
                  let options = item["options"]?.arrayValue else { return nil }
            let choices: [JSONValue] = options.compactMap { option in
                guard let label = option["label"]?.stringValue, !label.isEmpty else { return nil }
                var choice: [String: JSONValue] = ["const": .string(label), "title": .string(label)]
                if let detail = option["description"]?.stringValue, !detail.isEmpty { choice["description"] = .string(detail) }
                return .object(choice)
            }
            guard choices.count >= 2 else { return nil }
            var field: [String: JSONValue] = ["title": .string(item["header"]?.stringValue ?? ""), "description": .string(prompt)]
            if item["multiSelect"]?.boolValue == true {
                field["type"] = "array"
                field["items"] = ["anyOf": .array(choices)]
            } else {
                field["type"] = "string"
                field["oneOf"] = .array(choices)
            }
            properties["question_\(index)"] = .object(field)
            properties["question_\(index)_custom"] = ["type": "string", "title": "Other"]
        }
        let single = questions.count == 1 ? (questions[0]["question"]?.stringValue ?? "") : ""
        return ["mode": "form", "message": .string(single),
                "requestedSchema": ["type": "object", "properties": .object(properties)]]
    }

    /// 把表单响应整理成给模型看的文本(与 Claude Code 的格式一致)。
    /// - Parameters:
    ///   - response: `ElicitationPrompt` 的响应
    ///   - questions: 原始题目
    static func answerResult(response: JSONValue, questions: [JSONValue]) -> BridgeResult {
        guard response["action"]?.stringValue == "accept", let content = response["content"]?.objectValue else {
            return BridgeResult("The user dismissed the question(s) without answering. Do not ask again unless needed; proceed with your best judgment or ask in plain text.", isError: true)
        }
        var pairs: [String] = []
        for (index, item) in questions.enumerated() {
            guard let prompt = item["question"]?.stringValue else { continue }
            var answers: [String] = []
            if let value = content["question_\(index)"] {
                if let text = value.stringValue { answers.append(text) } else { answers += (value.arrayValue ?? []).compactMap(\.stringValue) }
            }
            if let custom = content["question_\(index)_custom"]?.stringValue, !custom.isEmpty { answers.append(custom) }
            pairs.append("\"\(prompt)\"=\"\(answers.joined(separator: ", "))\"")
        }
        return BridgeResult("User has answered your questions: \(pairs.joined(separator: ", ")). You can now continue with the user's answers in mind.")
    }
}
