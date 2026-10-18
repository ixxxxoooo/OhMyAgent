// @author ixxxxoooo
// MCP 工具身份识别:不同 ACP Agent 报告 MCP 工具调用的方式不同,这里统一还原成 (服务器, 工具)。
//
// - Claude Code(claude-agent-acp):`name` 即 `mcp__服务器__工具`;
// - OpenCode 2.x:所有 MCP 调用都包在一个叫 `execute` 的工具里,入参是 JS 代码
//   `tools.服务器.工具(...)` / `tools["服务器"]["工具"](...)`,结果的 `rawOutput.metadata.toolCalls[].tool`
//   形如 `服务器.工具`(并带 `input`)。一次 `execute` 可以调用多个 MCP 工具。
// 下游(MCP 工具行、画布卡片、分组规则)只通过本文件取身份,不再各自硬编码 `mcp__` 前缀。

import Foundation

/// 一次 MCP 工具调用的身份。
public struct McpToolRef: Sendable, Hashable {
    /// MCP 服务器名(如 `ohmyagent`)
    public var server: String
    /// 工具名(如 `canvas_create`)
    public var tool: String
    /// 该次调用的入参(OpenCode 取自结果元数据,拿不到为 nil)
    public var input: JSONValue?

    public init(server: String, tool: String, input: JSONValue? = nil) {
        self.server = server
        self.tool = tool
        self.input = input
    }

    /// Claude Code 风格的规范名 `mcp__服务器__工具`。
    public var canonicalName: String { "mcp__\(server)__\(tool)" }
}

/// MCP 身份解析。
public enum McpToolIdentity {
    /// 解析一个工具调用里的全部 MCP 调用(按出现顺序、去重);不是 MCP 工具返回空数组。
    /// - Parameters:
    ///   - name: 工具名(可空)
    ///   - rawInput: 归一化后的入参
    ///   - rawOutput: 原始出参
    /// - Returns: MCP 调用列表
    public static func refs(name: String?, rawInput: JSONValue?, rawOutput: JSONValue?) -> [McpToolRef] {
        if let name, let ref = parseCanonical(name) { return [ref] }
        // 已完成的结果里有权威清单
        if let calls = rawOutput?["metadata"]?["toolCalls"]?.arrayValue {
            let refs = calls.compactMap { call -> McpToolRef? in
                guard let full = call["tool"]?.stringValue, let dot = full.firstIndex(of: ".") else { return nil }
                let server = String(full[..<dot]), tool = String(full[full.index(after: dot)...])
                guard !server.isEmpty, !tool.isEmpty else { return nil }
                return McpToolRef(server: server, tool: tool, input: call["input"])
            }
            if !refs.isEmpty { return dedup(refs) }
        }
        // 运行中/尚无结果:从代码里解析
        guard let code = rawInput?["code"]?.stringValue else { return [] }
        return dedup(parseCode(code))
    }

    /// 解析 `mcp__服务器__工具`。
    /// - Parameter name: 工具名
    /// - Returns: 身份;不是该形态返回 nil
    public static func parseCanonical(_ name: String) -> McpToolRef? {
        guard name.hasPrefix("mcp__") else { return nil }
        let segments = name.components(separatedBy: "__")
        guard segments.count > 2 else { return nil }
        return McpToolRef(server: segments[1], tool: segments[2...].joined(separator: "__"))
    }

    /// 从 JS 代码里找 `tools.服务器.工具(` 与 `tools["服务器"]["工具"](`。
    private static func parseCode(_ code: String) -> [McpToolRef] {
        let patterns = [
            #"tools\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\s*\("#,
            #"tools\[\s*["']([^"']+)["']\s*\]\s*\[\s*["']([^"']+)["']\s*\]\s*\("#,
            #"tools\.([A-Za-z0-9_-]+)\[\s*["']([^"']+)["']\s*\]\s*\("#,
        ]
        let range = NSRange(code.startIndex..., in: code)
        var found: [(Int, McpToolRef)] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: code, range: range) where match.numberOfRanges == 3 {
                guard let a = Range(match.range(at: 1), in: code), let b = Range(match.range(at: 2), in: code) else { continue }
                found.append((match.range.location, McpToolRef(server: String(code[a]), tool: String(code[b]))))
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func dedup(_ refs: [McpToolRef]) -> [McpToolRef] {
        var seen = Set<String>()
        return refs.filter { seen.insert($0.canonicalName).inserted }
    }
}

public extension ToolCall {
    /// 该工具调用包含的全部 MCP 调用。
    var mcpRefs: [McpToolRef] { McpToolIdentity.refs(name: name, rawInput: rawInput, rawOutput: rawOutput) }

    /// 首个 MCP 调用(不是 MCP 工具为 nil)。
    var mcpRef: McpToolRef? { mcpRefs.first }

    /// 规范 MCP 工具名 `mcp__服务器__工具`(兼容 Claude Code 与 OpenCode);不是 MCP 工具为 nil。
    var mcpName: String? { mcpRef?.canonicalName }

    /// 是否调用了指定 MCP 工具(按工具名后缀匹配,与服务器无关)。
    /// - Parameter prefix: 工具名前缀,如 `canvas_`
    func callsMcpTool(withPrefix prefix: String) -> Bool { mcpRefs.contains { $0.tool.hasPrefix(prefix) } }

    /// MCP 调用的真实入参:Claude Code 取 `rawInput`;OpenCode 取结果元数据里的 `input`(代码入参不具可读性)。
    var mcpInput: JSONValue? {
        if name?.hasPrefix("mcp__") == true { return rawInput }
        return mcpRef?.input ?? rawInput
    }
}
