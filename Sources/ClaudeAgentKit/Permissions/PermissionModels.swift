// @author ixxxxoooo
// 权限模型:选项、持久化变更集(规范化与校验)、选项 ID。

import ACPKit
import Foundation

/// 权限选项 ID(与客户端约定,勿改)。
enum PermissionOptionID {
    static let allowOnce = "allow-once"
    static let allowWithUpdates = "allow-with-updates"
    static let allowSkillExact = "allow-skill-exact"
    static let allowSkillPrefix = "allow-skill-prefix"
    static let exitPlanBypass = "exit-plan-bypass"
    static let exitPlanAuto = "exit-plan-auto"
    static let exitPlanAcceptEdits = "exit-plan-accept-edits"
    static let exitPlanDefault = "exit-plan-default"
    static let exitPlanClearAuto = "exit-plan-clear-auto"
    static let exitPlanClearBypass = "exit-plan-clear-bypass"
    static let exitPlanClearAcceptEdits = "exit-plan-clear-accept-edits"
    static let reject = "reject"
}

/// 发给客户端的一个权限选项。
struct PermissionOption: Sendable, Equatable {
    var optionId: String
    var name: String
    var kind: String

    /// 序列化为 ACP `PermissionOption`。
    var json: JSONValue { ["optionId": .string(optionId), "name": .string(name), "kind": .string(kind)] }

    static func allowOnce(_ name: String = "Yes") -> PermissionOption { .init(optionId: PermissionOptionID.allowOnce, name: name, kind: "allow_once") }
    static func allowWithUpdates(_ name: String) -> PermissionOption { .init(optionId: PermissionOptionID.allowWithUpdates, name: name, kind: "allow_always") }
    static func reject(_ name: String = "No") -> PermissionOption { .init(optionId: PermissionOptionID.reject, name: name, kind: "reject_once") }
}

/// 经校验的持久化权限变更集(来自 CLI 的 `permission_suggestions`)。
struct DurableChangeSet: Sendable, Equatable {
    var updates: [JSONValue]

    private static let destinations: Set<String> = ["session", "cliArg", "userSettings", "projectSettings", "localSettings"]
    private static let behaviors: Set<String> = ["allow", "deny", "ask"]
    private static let modes: Set<String> = ["default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto"]

    /// 规范化并校验建议;任何一项不合法都整体丢弃(不给「始终允许」选项)。
    /// - Parameters:
    ///   - suggestions: CLI 给出的建议数组
    ///   - forcedAsk: 命中「必须询问」规则或禁止持久化时为 true
    static func normalize(_ suggestions: JSONValue?, forcedAsk: Bool = false) -> DurableChangeSet? {
        guard !forcedAsk, let list = suggestions?.arrayValue, !list.isEmpty, list.count <= 100, list.allSatisfy(isKnownUpdate) else { return nil }
        return DurableChangeSet(updates: list)
    }

    private static func safe(_ value: JSONValue?, max: Int) -> Bool {
        guard let text = value?.stringValue, text.count <= max, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !text.unicodeScalars.contains { scalar in
            let code = scalar.value
            return code <= 0x08 || code == 0x0B || code == 0x0C || (0x0E...0x1F).contains(code) || code == 0x7F
        }
    }

    private static func isRule(_ rule: JSONValue) -> Bool {
        guard rule.objectValue != nil, safe(rule["toolName"], max: 512) else { return false }
        return rule["ruleContent"] == nil || rule["ruleContent"]?.isNull == true || safe(rule["ruleContent"], max: 10_000)
    }

    private static func isKnownUpdate(_ update: JSONValue) -> Bool {
        guard update.objectValue != nil, let destination = update["destination"]?.stringValue, destinations.contains(destination),
              let type = update["type"]?.stringValue else { return false }
        switch type {
        case "addRules", "replaceRules", "removeRules":
            guard let rules = update["rules"]?.arrayValue, rules.count <= 100, type == "replaceRules" || !rules.isEmpty, rules.allSatisfy(isRule),
                  let behavior = update["behavior"]?.stringValue else { return false }
            return behaviors.contains(behavior)
        case "setMode":
            return update["mode"]?.stringValue.map(modes.contains) ?? false
        case "addDirectories", "removeDirectories":
            guard let directories = update["directories"]?.arrayValue, !directories.isEmpty, directories.count <= 100 else { return false }
            return directories.allSatisfy { safe($0, max: 4_096) }
        default:
            return false
        }
    }

    // MARK: 便捷查询

    /// 所有更新的规则列表(仅 `addRules`)。
    var addedRules: [JSONValue] {
        updates.filter { $0["type"]?.stringValue == "addRules" }.flatMap { $0["rules"]?.arrayValue ?? [] }
    }

    /// 是否恰好是「单条 localSettings 允许规则」且匹配工具名与内容。
    func isExactLocalAllowRule(toolName: String, ruleContent: String?) -> Bool {
        guard updates.count == 1, let update = updates.first, update["type"]?.stringValue == "addRules",
              update["behavior"]?.stringValue == "allow", update["destination"]?.stringValue == "localSettings",
              let rules = update["rules"]?.arrayValue, rules.count == 1, let rule = rules.first,
              rule["toolName"]?.stringValue == toolName else { return false }
        let content = rule["ruleContent"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ruleContent == nil ? (rule["ruleContent"] == nil || rule["ruleContent"]?.isNull == true) : content == ruleContent
    }

    /// 是否是针对某 MCP 工具的整体允许(无内容限定)。
    func isMcpAllow(toolName: String) -> Bool {
        !updates.isEmpty && updates.allSatisfy { update in
            guard update["type"]?.stringValue == "addRules", update["behavior"]?.stringValue == "allow",
                  let rules = update["rules"]?.arrayValue, !rules.isEmpty else { return false }
            return rules.allSatisfy { $0["toolName"]?.stringValue == toolName && ($0["ruleContent"] == nil || $0["ruleContent"]?.isNull == true) }
        }
    }
}
