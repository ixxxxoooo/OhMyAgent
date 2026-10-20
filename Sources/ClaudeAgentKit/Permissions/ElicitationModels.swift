// @author ixxxxoooo
// 表单征询:AskUserQuestion、MCP 征询与「拒绝回退」对话。

import ACPKit
import Foundation

/// AskUserQuestion 的一个问题。
struct AskQuestion: Sendable {
    var question: String
    var header: String?
    var multiSelect: Bool
    var options: [JSONValue]
}

/// 表单征询的编解码(纯函数)。
enum Elicitation {
    static let optionMetaKey = "_claude/askUserQuestionOption"

    /// 抽取合法的问题;没有合法问题返回 nil。
    static func questions(from input: JSONValue) -> [AskQuestion]? {
        guard let list = input["questions"]?.arrayValue else { return nil }
        let valid = list.compactMap { item -> AskQuestion? in
            guard let question = item["question"]?.stringValue, let options = item["options"]?.arrayValue, !options.isEmpty else { return nil }
            return AskQuestion(question: question, header: item["header"]?.nonEmptyString, multiSelect: item["multiSelect"]?.boolValue == true, options: options)
        }
        return valid.isEmpty ? nil : valid
    }

    static func fieldKey(_ index: Int) -> String { "question_\(index)" }
    static func customKey(_ index: Int) -> String { "question_\(index)_custom" }

    /// 构造 `elicitation/create` 请求(表单模式)。
    static func createRequest(_ questions: [AskQuestion], sessionId: String, toolCallId: String?) -> JSONValue {
        let single = questions.count == 1
        var properties: [String: JSONValue] = [:]
        for (index, question) in questions.enumerated() {
            let options: [JSONValue] = question.options.map { option in
                let label = option["label"]?.stringValue ?? ""
                var entry: [String: JSONValue] = ["const": .string(label), "title": .string(label)]
                if let description = option["description"]?.nonEmptyString { entry["description"] = .string(description) }
                if let preview = option["preview"], !preview.isNull, preview.stringValue != "" { entry["_meta"] = .object([optionMetaKey: ["preview": preview]]) }
                return .object(entry)
            }
            var field: [String: JSONValue] = question.multiSelect
                ? ["type": "array", "items": ["anyOf": .array(options)]]
                : ["type": "string", "oneOf": .array(options)]
            if let header = question.header { field["title"] = .string(header) }
            if !single { field["description"] = .string(question.question) }
            properties[fieldKey(index)] = .object(field)
            properties[customKey(index)] = [
                "type": "string", "title": "Other",
                "description": .string(question.multiSelect ? "Type your own answer to add to your selection above (optional)." : "Type your own answer, or add a note to the option you chose above (optional)."),
            ]
        }
        var request: [String: JSONValue] = [
            "mode": "form", "sessionId": .string(sessionId),
            "message": .string(single ? question0(questions) : "Please answer the following questions."),
            "requestedSchema": ["type": "object", "properties": .object(properties)],
        ]
        if let toolCallId { request["toolCallId"] = .string(toolCallId) }
        return .object(request)
    }

    private static func question0(_ questions: [AskQuestion]) -> String { questions.first?.question ?? "" }

    private static func joinMulti(_ items: [String]) -> String {
        items.map { $0.contains(", ") || $0.contains("\"") ? (JSONValue.string($0).jsonText) : $0 }.joined(separator: ", ")
    }

    /// 应用征询响应;取消返回 nil。
    static func applyAnswer(_ response: JSONValue, input: JSONValue, questions: [AskQuestion]) -> JSONValue? {
        var base = input.objectValue ?? [:]
        switch response["action"]?.stringValue {
        case "decline":
            base["answers"] = .object([:])
            return .object(base)
        case "accept": break
        default: return nil
        }
        let content = response["content"] ?? [:]
        var answers: [String: JSONValue] = [:], annotations: [String: JSONValue] = [:]
        for (index, question) in questions.enumerated() {
            let customText = content[customKey(index)]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = content[fieldKey(index)]
            let picks: [String]
            if let array = value?.arrayValue {
                picks = array.compactMap { item in item.isNull ? nil : (item.stringValue ?? scalarText(item)) }.filter { !$0.isEmpty }
            } else if let value, !value.isNull {
                picks = [value.stringValue ?? scalarText(value) ?? ""]
            } else {
                picks = []
            }
            if question.multiSelect {
                let text = joinMulti(customText.isEmpty ? picks : picks + [customText])
                if !text.isEmpty { answers[question.question] = .string(text) }
                continue
            }
            let picked = picks.joined(separator: ", ")
            if picked.isEmpty {
                if !customText.isEmpty { answers[question.question] = .string(customText) }
                continue
            }
            answers[question.question] = .string(picked)
            if !customText.isEmpty { annotations[question.question] = ["notes": .string(customText)] }
        }
        base["answers"] = .object(answers)
        if !annotations.isEmpty { base["annotations"] = .object(annotations) }
        return .object(base)
    }

    private static func scalarText(_ value: JSONValue) -> String? {
        if let int = value.intValue { return String(int) }
        if let double = value.doubleValue { return String(double) }
        if let bool = value.boolValue { return String(bool) }
        return nil
    }

    // MARK: MCP 征询

    /// MCP 征询 → `elicitation/create` 请求;无法表示时返回 nil。
    static func mcpRequest(_ request: JSONValue, sessionId: String) -> JSONValue? {
        if request["mode"]?.stringValue == "url" {
            guard let url = request["url"]?.stringValue, !url.isEmpty else { return nil }
            return ["mode": "url", "sessionId": .string(sessionId), "message": request["message"] ?? "", "url": .string(url),
                    "elicitationId": .string(request["elicitationId"]?.stringValue ?? UUID().uuidString)]
        }
        var schema = request["requestedSchema"]?.objectValue ?? [:]
        schema["type"] = "object"
        if schema["properties"] == nil, request["requestedSchema"]?.objectValue == nil { schema["properties"] = .object([:]) }
        return ["mode": "form", "sessionId": .string(sessionId), "message": request["message"] ?? "", "requestedSchema": .object(schema)]
    }

    /// 客户端响应 → CLI 征询结果。
    static func mcpResult(_ response: JSONValue) -> JSONValue {
        switch response["action"]?.stringValue {
        case "accept": return ["action": "accept", "content": response["content"] ?? [:]]
        case "decline": return ["action": "decline"]
        default: return ["action": "cancel"]
        }
    }

    // MARK: 拒绝回退

    static let refusalDialogKind = "refusal_fallback_prompt"

    /// 拒绝回退对话 → 表单请求。
    static func refusalRequest(payload: JSONValue, sessionId: String) -> JSONValue? {
        guard let original = payload["originalModel"]?.stringValue, let fallback = payload["fallbackModel"]?.stringValue else { return nil }
        let category = payload["apiRefusalCategory"]?.stringValue.map { " (\($0))" } ?? ""
        let guidance = payload["guidanceText"]?.nonEmptyString.map { "\n\n\($0)" } ?? ""
        return [
            "mode": "form", "sessionId": .string(sessionId),
            "message": .string("\(original) declined this request\(category). Retry with \(fallback)?\(guidance)"),
            "requestedSchema": ["type": "object", "properties": ["choice": ["type": "string", "oneOf": [
                ["const": "retry_fallback", "title": .string("Retry with \(fallback)"), "description": .string("The session continues on \(fallback).")],
                ["const": "cancelled", "title": "Keep the refusal", "description": "You can send a new message."],
            ]]]],
        ]
    }

    /// 回退对话的结果。
    static func refusalResult(_ response: JSONValue) -> String {
        response["action"]?.stringValue == "accept" && response.at("content", "choice")?.stringValue == "retry_fallback" ? "retry_fallback" : "cancelled"
    }
}
