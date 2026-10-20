// @author ixxxxoooo
// 斜杠命令清单:把 CLI 报告的命令转换成 ACP `available_commands_update` 的条目。

import ACPKit
import Foundation

/// 斜杠命令。
enum SlashCommands {
    /// 适配器自己处理的 `/mcp` 命令条目。
    static let mcp: JSONValue = [
        "name": "mcp",
        "description": "Show the MCP servers and their status, or reconnect, enable, or disable a server",
        "input": ["hint": "[reconnect|enable|disable [<server>|all]]"],
    ]

    /// 客户端不支持(需要终端交互)的命令。
    static let unsupported: Set<String> = ["clear", "cost", "keybindings-help", "login", "logout", "output-style:new", "release-notes", "todos"]

    /// 只在本地执行、不进入模型上下文的命令。
    static let localOnly: Set<String> = ["/context", "/heapdump", "/extra-usage"]

    /// 生成对外公布的命令列表。
    /// - Parameters:
    ///   - commands: CLI 的命令清单(`name`/`description`/`argumentHint`)
    ///   - terminal: 只能在终端使用的命令名(不公布)
    /// - Returns: `availableCommands` 条目(末尾附 `/mcp`)
    static func advertised(_ commands: [JSONValue], terminal: [String]) -> [JSONValue] {
        var result: [JSONValue] = []
        for command in commands {
            guard let raw = command["name"]?.nonEmptyString, raw != "mcp", !terminal.contains(raw) else { continue }
            var name = raw
            if raw.hasSuffix(" (MCP)") { name = "mcp:" + raw.replacingOccurrences(of: " (MCP)", with: "") }
            if unsupported.contains(name) { continue }
            var hint: String?
            if let text = command["argumentHint"]?.nonEmptyString {
                hint = text
            } else if let list = command["argumentHint"]?.arrayValue {
                let joined = list.compactMap(\.stringValue).joined(separator: " ")
                hint = joined.isEmpty ? nil : joined
            }
            result.append(["name": .string(name), "description": .string(command["description"]?.stringValue ?? ""), "input": hint.map { ["hint": .string($0)] } ?? .null])
        }
        result.append(mcp)
        return result
    }
}
