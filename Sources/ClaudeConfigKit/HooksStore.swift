// @author ygw
// Hooks 读写:settings.json 的 `hooks`(事件 → matcher 组 → 处理器),插件 hooks.json 只读。

import Foundation

/// 单个处理器。
public struct HookHandler: Sendable, Equatable {
    public var type: String          // command / http / prompt / agent / mcp_tool
    public var command: String
    public var url: String
    public var prompt: String
    public var timeout: Int?

    public init(type: String = "command", command: String = "", url: String = "", prompt: String = "", timeout: Int? = nil) {
        self.type = type
        self.command = command
        self.url = url
        self.prompt = prompt
        self.timeout = timeout
    }

    init(dictionary: [String: Any]) {
        self.init(type: dictionary["type"] as? String ?? "command", command: dictionary["command"] as? String ?? "",
                  url: dictionary["url"] as? String ?? "", prompt: dictionary["prompt"] as? String ?? "",
                  timeout: (dictionary["timeout"] as? NSNumber)?.intValue)
    }

    func apply(to dictionary: inout [String: Any]) {
        dictionary["type"] = type
        func put(_ key: String, _ value: String) { if value.isEmpty { dictionary.removeValue(forKey: key) } else { dictionary[key] = value } }
        put("command", type == "command" ? command : "")
        put("url", type == "http" ? url : "")
        put("prompt", (type == "prompt" || type == "agent") ? prompt : "")
        if let timeout { dictionary["timeout"] = timeout } else { dictionary.removeValue(forKey: "timeout") }
    }

    /// 一行摘要。
    public var summary: String {
        switch type {
        case "command": return command
        case "http": return url
        case "prompt", "agent": return prompt
        default: return command.isEmpty ? type : command
        }
    }
}

/// 展平后的 Hook 条目(用于只读汇总与定位编辑)。
public struct HookEntry: Sendable, Identifiable, Equatable {
    public enum Origin: Sendable, Equatable {
        case settings(ConfigScope)
        case plugin(String)
        public var displayName: String {
            switch self {
            case .settings(let scope): return "\(scope.displayName)设置"
            case .plugin(let name): return "插件 \(name)"
            }
        }
    }
    public var id: String { "\(origin.displayName)/\(event)/\(groupIndex)/\(handlerIndex)" }
    public var origin: Origin
    public var event: String
    public var matcher: String
    public var groupIndex: Int
    public var handlerIndex: Int
    public var handler: HookHandler
}

/// Hooks 存储。
public struct HooksStore: Sendable {
    public var paths: ClaudePaths
    public var pluginRoots: [String: URL]

    public init(paths: ClaudePaths, pluginRoots: [String: URL] = [:]) {
        self.paths = paths
        self.pluginRoots = pluginRoots
    }

    /// 支持的事件。
    public static let events: [String] = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure",
        "Notification", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "PreCompact", "PostCompact", "InstructionsLoaded", "TeammateIdle",
    ]
    public static let handlerTypes = ["command", "http", "prompt", "agent", "mcp_tool"]

    // MARK: - 读取

    /// 列出所有来源的 Hook。
    public func list() throws -> [HookEntry] {
        var entries: [HookEntry] = []
        for scope in ConfigScope.allCases {
            let settings = try SettingsStore(paths: paths).read(scope)
            entries += Self.flatten(settings["hooks"] as? [String: Any], origin: .settings(scope))
        }
        for (plugin, root) in pluginRoots.sorted(by: { $0.key < $1.key }) {
            let file = root.appendingPathComponent("hooks/hooks.json")
            if let object = try? JSONFile(file).read() {
                entries += Self.flatten((object["hooks"] as? [String: Any]) ?? object, origin: .plugin(plugin))
            }
        }
        return entries
    }

    static func flatten(_ hooks: [String: Any]?, origin: HookEntry.Origin) -> [HookEntry] {
        guard let hooks else { return [] }
        var result: [HookEntry] = []
        for event in hooks.keys.sorted() {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            for (groupIndex, group) in groups.enumerated() {
                let matcher = group["matcher"] as? String ?? ""
                for (handlerIndex, raw) in ((group["hooks"] as? [[String: Any]]) ?? []).enumerated() {
                    result.append(HookEntry(origin: origin, event: event, matcher: matcher, groupIndex: groupIndex,
                                            handlerIndex: handlerIndex, handler: HookHandler(dictionary: raw)))
                }
            }
        }
        return result
    }

    // MARK: - 写入

    /// 添加处理器:matcher 相同的组会被复用。
    /// - Parameters:
    ///   - handler: 处理器
    ///   - event: 事件名
    ///   - matcher: 匹配器(空表示全部)
    ///   - scope: 目标设置层
    public func add(_ handler: HookHandler, event: String, matcher: String, scope: ConfigScope) throws {
        if let first = Self.validate(handler: handler, event: event, matcher: matcher).first { throw ConfigError.invalidValue(first) }
        try mutateHooks(scope) { hooks in
            var groups = hooks[event] as? [[String: Any]] ?? []
            var newHandler: [String: Any] = [:]
            handler.apply(to: &newHandler)
            if let index = groups.firstIndex(where: { ($0["matcher"] as? String ?? "") == matcher }) {
                var handlers = groups[index]["hooks"] as? [[String: Any]] ?? []
                handlers.append(newHandler)
                groups[index]["hooks"] = handlers
            } else {
                var group: [String: Any] = ["hooks": [newHandler]]
                if !matcher.isEmpty { group["matcher"] = matcher }
                groups.append(group)
            }
            hooks[event] = groups
        }
    }

    /// 更新已有处理器(保留该处理器的未知字段)。
    public func update(_ entry: HookEntry, handler: HookHandler, matcher: String) throws {
        guard case .settings(let scope) = entry.origin else { throw ConfigError.invalidValue("插件内的 Hook 是只读的") }
        if let first = Self.validate(handler: handler, event: entry.event, matcher: matcher).first { throw ConfigError.invalidValue(first) }
        try mutateHooks(scope) { hooks in
            guard var groups = hooks[entry.event] as? [[String: Any]], groups.indices.contains(entry.groupIndex),
                  var handlers = groups[entry.groupIndex]["hooks"] as? [[String: Any]], handlers.indices.contains(entry.handlerIndex) else { return }
            var dictionary = handlers[entry.handlerIndex]
            handler.apply(to: &dictionary)
            handlers[entry.handlerIndex] = dictionary
            groups[entry.groupIndex]["hooks"] = handlers
            if matcher.isEmpty { groups[entry.groupIndex].removeValue(forKey: "matcher") } else { groups[entry.groupIndex]["matcher"] = matcher }
            hooks[entry.event] = groups
        }
    }

    /// 删除处理器;组或事件变空时一并清理。
    public func remove(_ entry: HookEntry) throws {
        guard case .settings(let scope) = entry.origin else { throw ConfigError.invalidValue("插件内的 Hook 是只读的") }
        try mutateHooks(scope) { hooks in
            guard var groups = hooks[entry.event] as? [[String: Any]], groups.indices.contains(entry.groupIndex),
                  var handlers = groups[entry.groupIndex]["hooks"] as? [[String: Any]], handlers.indices.contains(entry.handlerIndex) else { return }
            handlers.remove(at: entry.handlerIndex)
            if handlers.isEmpty { groups.remove(at: entry.groupIndex) } else { groups[entry.groupIndex]["hooks"] = handlers }
            if groups.isEmpty { hooks.removeValue(forKey: entry.event) } else { hooks[entry.event] = groups }
        }
    }

    private func mutateHooks(_ scope: ConfigScope, _ body: (inout [String: Any]) -> Void) throws {
        guard let url = paths.settingsFile(scope) else { throw ConfigError.invalidValue("当前没有工作区,无法写入\(scope.displayName)设置") }
        try JSONFile(url).update { root in
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            body(&hooks)
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
    }

    // MARK: - 校验

    /// 校验,返回问题列表。
    public static func validate(handler: HookHandler, event: String, matcher: String) -> [String] {
        var problems: [String] = []
        if !events.contains(event) { problems.append("未知事件「\(event)」") }
        if !handlerTypes.contains(handler.type) { problems.append("未知处理器类型「\(handler.type)」") }
        if handler.type == "command", handler.command.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("command 类型需要填写命令") }
        if handler.type == "http" {
            let scheme = URL(string: handler.url)?.scheme?.lowercased()
            if scheme != "http" && scheme != "https" { problems.append("http 类型需要有效的 URL") }
        }
        if (handler.type == "prompt" || handler.type == "agent"), handler.prompt.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(handler.type) 类型需要填写提示词") }
        if let timeout = handler.timeout, timeout <= 0 { problems.append("超时必须大于 0 秒") }
        if !matcher.isEmpty, matcher != "*", (try? NSRegularExpression(pattern: matcher)) == nil { problems.append("matcher 不是合法的正则表达式") }
        return problems
    }
}
