// @author ixxxxoooo
// 权限选择 → CLI `can_use_tool` 响应(允许/拒绝与持久化更新)。

import ACPKit
import Foundation

/// 权限决策错误。
enum PermissionError: Error, Equatable {
    /// 客户端取消或未选择(调用方应终止这次工具调用)
    case aborted
    /// 选项未被提供或输入非法
    case invalid(String)
}

/// 权限决策结果。
struct PermissionDecision: Sendable {
    /// 回给 CLI 的响应体
    var result: JSONValue
    /// 若为「清空上下文并实施计划」,为目标模式
    var contextResetMode: String?

    var isAllow: Bool { result["behavior"]?.stringValue == "allow" }
    var updatedPermissions: [JSONValue] { result["updatedPermissions"]?.arrayValue ?? [] }
}

/// 把客户端的权限响应解码成 CLI 响应。
enum PermissionDecoder {
    /// ExitPlanMode 的「清空上下文」选项对应的模式。
    static func clearContextMode(_ optionId: String) -> String? {
        switch optionId {
        case PermissionOptionID.exitPlanClearAuto: return "auto"
        case PermissionOptionID.exitPlanClearBypass: return "bypassPermissions"
        case PermissionOptionID.exitPlanClearAcceptEdits: return "acceptEdits"
        default: return nil
        }
    }

    private static func exitPlanMode(_ optionId: String) -> String? {
        switch optionId {
        case PermissionOptionID.exitPlanBypass: return "bypassPermissions"
        case PermissionOptionID.exitPlanAuto: return "auto"
        case PermissionOptionID.exitPlanAcceptEdits: return "acceptEdits"
        case PermissionOptionID.exitPlanDefault: return "default"
        default: return nil
        }
    }

    /// 解码客户端响应。
    /// - Throws: `PermissionError`(取消、未提供的选项、非法输入)
    static func decode(response: JSONValue, toolName: String, input: JSONValue, toolUseID: String?, offered: [PermissionOption], durable: DurableChangeSet?) throws -> PermissionDecision {
        guard response.at("outcome", "outcome")?.stringValue == "selected", let optionId = response.at("outcome", "optionId")?.stringValue else {
            throw PermissionError.aborted
        }
        guard offered.contains(where: { $0.optionId == optionId }) else { throw PermissionError.invalid("Permission option was not offered: \(optionId)") }
        let reset = toolName == "ExitPlanMode" ? clearContextMode(optionId) : nil
        let context = Context(input: input, toolUseID: toolUseID, durable: durable)
        let result = try apply(optionId: optionId, toolName: toolName, context: context, reset: reset)
        return PermissionDecision(result: result, contextResetMode: reset)
    }

    private struct Context {
        var input: JSONValue
        var toolUseID: String?
        var durable: DurableChangeSet?
    }

    private static func allow(_ context: Context, _ updates: [JSONValue]? = nil, permanent: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = ["behavior": "allow", "updatedInput": context.input, "decisionClassification": .string(permanent ? "user_permanent" : "user_temporary")]
        if let updates { object["updatedPermissions"] = .array(updates) }
        if let id = context.toolUseID { object["toolUseID"] = .string(id) }
        return .object(object)
    }

    private static func deny(_ context: Context, _ message: String = "User refused permission to run tool", interrupt: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = ["behavior": "deny", "message": .string(message), "decisionClassification": "user_reject"]
        if interrupt { object["interrupt"] = true }
        if let id = context.toolUseID { object["toolUseID"] = .string(id) }
        return .object(object)
    }

    private static func localAllowRule(_ toolName: String, _ ruleContent: String? = nil) -> [JSONValue] {
        var rule: [String: JSONValue] = ["toolName": .string(toolName)]
        if let ruleContent { rule["ruleContent"] = .string(ruleContent) }
        return [["type": "addRules", "rules": [.object(rule)], "behavior": "allow", "destination": "localSettings"]]
    }

    private static func common(_ optionId: String, _ context: Context) throws -> JSONValue {
        switch optionId {
        case PermissionOptionID.allowOnce: return allow(context)
        case PermissionOptionID.allowWithUpdates:
            guard let durable = context.durable else { throw PermissionError.invalid("Invalid durable permission selection") }
            return allow(context, durable.updates, permanent: true)
        case PermissionOptionID.reject: return deny(context)
        default: throw PermissionError.invalid("Unknown permission option: \(optionId)")
        }
    }

    private static func generated(_ optionId: String, _ context: Context, _ updates: () throws -> [JSONValue]) throws -> JSONValue {
        guard optionId == PermissionOptionID.allowWithUpdates else { return try common(optionId, context) }
        return allow(context, try updates(), permanent: true)
    }

    private static func apply(optionId: String, toolName: String, context: Context, reset: String?) throws -> JSONValue {
        switch toolName {
        case "Skill":
            let skill = context.input["skill"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch optionId {
            case PermissionOptionID.allowSkillExact:
                guard !skill.isEmpty, skill.count <= 1_000 else { throw PermissionError.invalid("Invalid Skill permission input") }
                return allow(context, localAllowRule("Skill", skill), permanent: true)
            case PermissionOptionID.allowSkillPrefix:
                guard !skill.isEmpty, skill.count <= 1_000, let space = skill.firstIndex(of: " "), space != skill.startIndex else {
                    throw PermissionError.invalid("Skill prefix permission requires arguments")
                }
                return allow(context, localAllowRule("Skill", "\(skill[..<space]):*"), permanent: true)
            default: return try common(optionId, context)
            }
        case "WebFetch":
            return try generated(optionId, context) {
                guard let url = context.input["url"]?.stringValue, let host = URL(string: url)?.host, !host.isEmpty else {
                    throw PermissionError.invalid("Invalid WebFetch permission input")
                }
                return localAllowRule("WebFetch", "domain:\(host)")
            }
        case "ExitPlanMode":
            if reset != nil { return deny(context, "User accepted the plan and requested a fresh context", interrupt: true) }
            if let mode = exitPlanMode(optionId) {
                return allow(context, [["type": "setMode", "mode": .string(mode), "destination": "session"]], permanent: mode != "default")
            }
            if optionId == PermissionOptionID.reject { return deny(context, "User chose to keep planning", interrupt: true) }
            return try common(optionId, context)
        case "EnterPlanMode", "Read", "Bash", "PowerShell", "Glob", "Grep", "Edit", "Write", "NotebookEdit", "SandboxNetworkAccess":
            return try common(optionId, context)
        default:
            if toolName.hasPrefix("mcp__") { return try common(optionId, context) }
            return try generated(optionId, context) { localAllowRule(toolName) }
        }
    }
}
