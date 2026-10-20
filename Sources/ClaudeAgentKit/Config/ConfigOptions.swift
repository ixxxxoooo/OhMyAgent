// @author ixxxxoooo
// 会话配置项:权限模式、思考强度、Fast 模式、主线程 Agent 的选项构造与取值解析。

import ACPKit
import Foundation

/// 权限模式(`session/set_mode` 与 `mode` 配置项)。
enum PermissionModes {
    static let configId = "mode"
    /// Auto 不可用时回退到的模式
    static let autoFallback = "acceptEdits"
    static let autoFallbackReason = "the selected model does not support Auto mode; using Accept edits instead."

    private static let aliases: [String: String] = [
        "auto": "auto", "default": "default", "manual": "default", "acceptedits": "acceptEdits",
        "dontask": "dontAsk", "plan": "plan", "bypasspermissions": "bypassPermissions", "bypass": "bypassPermissions",
    ]

    /// 解析模式字符串(设置里的 `defaultMode`、恢复的转录模式)。
    /// - Returns: 规范化模式;无法识别返回 nil 并经 `onReject` 报告原因
    static func resolve(_ value: JSONValue?, allowBypass: Bool, onReject: (String) -> Void = { _ in }) -> String {
        guard let value else { return "default" }
        guard let text = value.stringValue else { onReject("expected a string"); return "default" }
        let normalized = text.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized.isEmpty { onReject("expected a non-empty string"); return "default" }
        guard let mapped = aliases[normalized] else { onReject("unknown value '\(text)'"); return "default" }
        if mapped == "bypassPermissions", !allowBypass { onReject("bypassPermissions not available"); return "default" }
        return mapped
    }

    /// 初始权限模式:显式 > 恢复会话的转录 > 设置默认。
    static func initial(explicit: String?, resumed: String?, defaultMode: JSONValue?, allowBypass: Bool) -> String {
        if let explicit { return resolve(.string(explicit), allowBypass: allowBypass) }
        if let resumed {
            var rejected = false
            let mode = resolve(.string(resumed), allowBypass: allowBypass, onReject: { _ in rejected = true })
            if !rejected { return mode }
        }
        return resolve(defaultMode, allowBypass: allowBypass)
    }

    /// 可用模式清单。
    static func available(allowBypass: Bool) -> [(id: String, name: String, description: String)] {
        var modes = [
            ("default", "Manual", "Always ask before making changes"),
            ("acceptEdits", "Accept edits", "Automatically accept all file edits"),
            ("plan", "Plan", "Create a plan before making changes"),
            ("auto", "Auto", "Claude handles permission decisions"),
        ]
        if allowBypass { modes.append(("bypassPermissions", "Bypass permissions", "Accepts all permissions")) }
        return modes
    }

    /// 模式配置项。
    static func configOption(current: String, available: [(id: String, name: String, description: String)]) -> JSONValue {
        ["id": "mode", "name": "Mode", "description": "Session permission mode", "category": "mode", "type": "select",
         "currentValue": .string(current),
         "options": .array(available.map { ["value": .string($0.id), "name": .string($0.name), "description": .string($0.description)] })]
    }

    /// 校验 `set_mode` 的取值。
    static func parse(_ id: String) -> String? {
        ["auto", "default", "acceptEdits", "bypassPermissions", "dontAsk", "plan"].contains(id) ? id : nil
    }
}

/// 思考强度。
enum EffortOptions {
    static let configId = "effort"

    /// 把选项值转成 CLI 的 `effortLevel`(`default` → null)。
    static func sdkLevel(_ value: String?) -> JSONValue {
        guard let value, value != "default" else { return .null }
        return .string(value)
    }

    /// `apply_flag_settings` 的设置体。
    static func flagSettings(_ value: String?, ultracode: Bool) -> JSONValue {
        var body: [String: JSONValue] = ["effortLevel": sdkLevel(value)]
        if ultracode { body["ultracode"] = true }
        return .object(body)
    }

    private static func canonicalKey(_ value: String) -> String {
        Rx.replace("-(\\d+m)$", value.trimmingCharacters(in: .whitespaces).lowercased(), with: "[$1]")
    }

    /// 设置里对该模型的强度偏好(按模型设置 > 全局)。
    static func settingsEffort(_ settings: ClaudeSettings, model: ModelInfo?, modelId: String? = nil) -> String? {
        for key in [model?.resolvedModel, model?.value, modelId].compactMap({ $0 }) {
            if let exact = settings.modelSettings[key]?["effortLevel"]?.stringValue { return exact }
            let canonical = canonicalKey(key)
            if let entry = settings.modelSettings.first(where: { canonicalKey($0.key) == canonical }), let level = entry.value["effortLevel"]?.stringValue { return level }
        }
        return settings.effortLevel
    }

    static func displayName(_ level: String) -> String {
        level.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// 强度配置项;当前模型不支持强度时返回 nil。
    static func configOption(infos: [ModelInfo], currentModelId: String, current: String?) -> JSONValue? {
        guard let info = infos.first(where: { $0.value == currentModelId }), info.supportsEffort, !info.supportedEffortLevels.isEmpty else { return nil }
        let levels = info.supportedEffortLevels
        var options: [JSONValue] = [["value": "default", "name": "Default"]]
        options += levels.map { ["value": .string($0), "name": .string(displayName($0))] }
        let value = current.flatMap { $0 == "default" || levels.contains($0) ? $0 : nil } ?? "default"
        return ["id": "effort", "name": "Effort", "description": "Available effort levels for this model", "category": "thought_level",
                "type": "select", "currentValue": .string(value), "options": .array(options)]
    }
}

/// Fast 模式。
enum FastModeOptions {
    static let configId = "fast"
    private static let reasons: [String: String] = [
        "free": "not available on the free plan",
        "extra_usage_disabled": "requires extra usage to be enabled for this account",
        "model_not_allowed": "not available for the selected model",
        "not_first_party": "not available on this API provider",
        "disabled_by_env": "disabled by environment configuration",
        "network_error": "eligibility could not be verified (network error)",
    ]

    static func enabled(state: String?) -> Bool { state != nil && state != "off" }
    /// 禁用原因的人话解释。
    static func explanation(_ reason: String) -> String? { reasons[reason] }
    static func normalizeReason(_ reason: String?) -> String? { reason.flatMap { reasons[$0] != nil ? $0 : nil } }

    static func configOption(enabled: Bool, boolean: Bool, disabledReason: String?) -> JSONValue {
        let explanation = enabled ? nil : disabledReason.flatMap { reasons[$0] }
        let description = "Faster responses on supported models" + (explanation.map { " — \($0)" } ?? "")
        var option: [String: JSONValue] = ["id": "fast", "name": "Fast mode", "description": .string(description), "category": "model_config"]
        if boolean {
            option["type"] = "boolean"
            option["currentValue"] = .bool(enabled)
        } else {
            option["type"] = "select"
            option["currentValue"] = .string(enabled ? "on" : "off")
            option["options"] = [["value": "on", "name": "On"], ["value": "off", "name": "Off"]]
        }
        return .object(option)
    }

    /// 解析 `fast` 的设置值。
    static func parse(_ value: JSONValue) -> Bool? {
        if let flag = value.boolValue { return flag }
        switch value.stringValue {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }
}

/// 主线程 Agent 选项。
enum AgentOptions {
    static let configId = "agent"
    static let defaultId = "__default__"
    static let builtin: Set<String> = ["claude", "general-purpose", "Explore", "Plan", "statusline-setup"]

    /// 从 CLI 的 agents 清单里挑出自定义 Agent。
    static func custom(from agents: JSONValue?) -> [(name: String, description: String)] {
        (agents?.arrayValue ?? []).compactMap { item in
            guard let name = item["name"]?.nonEmptyString, !builtin.contains(name), name != defaultId else { return nil }
            return (name, item["description"]?.stringValue ?? "")
        }
    }

    static func configOption(current: String, agents: [(name: String, description: String)]) -> JSONValue? {
        guard !agents.isEmpty else { return nil }
        var options: [JSONValue] = [["value": .string(defaultId), "name": "Default", "description": "Standard Claude Code agent"]]
        options += agents.map { JSONValue.make([("value", .string($0.name)), ("name", .string($0.name)), ("description", $0.description.isEmpty ? nil : .string($0.description))]) }
        return ["id": "agent", "name": "Agent", "description": "Main-thread agent persona", "type": "select", "currentValue": .string(current), "options": .array(options)]
    }
}
