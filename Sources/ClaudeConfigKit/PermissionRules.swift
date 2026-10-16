// @author ixxxxoooo
// 权限规则:`Tool` 或 `Tool(specifier)` 语法的解析、校验与匹配测试;allow / ask / deny 三类规则的读写。

import Foundation

/// 规则类别。
public enum PermissionBehavior: String, Sendable, CaseIterable, Identifiable {
    case allow, ask, deny
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .allow: return String(localized: "允许")
        case .ask: return String(localized: "询问")
        case .deny: return String(localized: "拒绝")
        }
    }
}

/// 解析后的规则。
public struct PermissionRule: Sendable, Equatable {
    public var tool: String
    public var specifier: String?

    /// 解析规则文本。
    /// - Parameter text: 如 `Bash(npm run test:*)`、`Read(./.env)`、`WebFetch`
    /// - Returns: 规则;格式不合法返回 nil
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.firstIndex(of: "(") {
            guard trimmed.hasSuffix(")") else { return nil }
            let tool = String(trimmed[..<open])
            let specifier = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            guard Self.isValidTool(tool) else { return nil }
            self.tool = tool
            self.specifier = specifier
        } else {
            guard Self.isValidTool(trimmed) else { return nil }
            tool = trimmed
            specifier = nil
        }
    }

    private static func isValidTool(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_:.*-]*$", options: .regularExpression) != nil
    }

    /// 校验,返回问题说明(空表示通过)。
    public static func validate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return String(localized: "规则不能为空") }
        if PermissionRule(trimmed) == nil { return String(localized: "格式应为 Tool 或 Tool(规则),括号需成对") }
        if let rule = PermissionRule(trimmed), let specifier = rule.specifier {
            if specifier.isEmpty { return String(localized: "括号内不能为空;不带限定请直接写工具名") }
            if rule.tool == "Bash", specifier.contains(":*"), !specifier.hasSuffix(":*") { return String(localized: "Bash 的 :* 前缀通配只能放在末尾") }
        }
        return nil
    }

    /// 测试某次工具调用是否命中规则。
    /// - Parameters:
    ///   - tool: 工具名(如 Bash、Read、mcp__server__tool)
    ///   - argument: 工具的主要参数(命令、文件路径或 URL),无参数传 nil
    public func matches(tool name: String, argument: String?) -> Bool {
        // MCP 工具:`mcp__server` 匹配该服务器的全部工具
        if tool.hasPrefix("mcp__"), specifier == nil {
            return name == tool || name.hasPrefix(tool + "__")
        }
        guard name == tool else { return false }
        guard let specifier else { return true }
        guard let argument else { return false }
        if specifier.hasSuffix(":*") {
            let prefix = String(specifier.dropLast(2))
            return argument == prefix || argument.hasPrefix(prefix + " ")
        }
        return Self.glob(specifier, matches: argument)
    }

    /// `*` 匹配任意字符(含 `/`),`**` 等价;其余字符按字面匹配。
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*\\*", with: ".*")
            .replacingOccurrences(of: "\\*", with: ".*")
        return text.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }
}

/// 权限规则存储(读写某层 settings.json 的 `permissions`)。
public struct PermissionsStore: Sendable {
    public var settings: SettingsStore

    public init(paths: ClaudePaths) { settings = SettingsStore(paths: paths) }

    /// 某层的规则列表。
    public func rules(_ behavior: PermissionBehavior, in scope: ConfigScope) -> [String] {
        settings.value(["permissions", behavior.rawValue], in: scope) as? [String] ?? []
    }

    /// 覆盖写入规则列表(空数组删除该键)。
    public func setRules(_ rules: [String], _ behavior: PermissionBehavior, in scope: ConfigScope) throws {
        for rule in rules { if let problem = PermissionRule.validate(rule) { throw ConfigError.invalidValue("\(rule):\(problem)") } }
        var seen = Set<String>()
        let unique = rules.filter { seen.insert($0).inserted }
        try settings.set(["permissions", behavior.rawValue], to: unique.isEmpty ? nil : unique, in: scope)
    }

    /// 汇总各层规则并测试一次调用的结果(deny > ask > allow;都未命中返回 nil,即走默认模式)。
    /// - Returns: 命中的行为、规则文本与所在层
    public func evaluate(tool: String, argument: String?) -> (behavior: PermissionBehavior, rule: String, scope: ConfigScope)? {
        for behavior in [PermissionBehavior.deny, .ask, .allow] {
            for scope in [ConfigScope.local, .project, .user] {
                for text in rules(behavior, in: scope) {
                    if let rule = PermissionRule(text), rule.matches(tool: tool, argument: argument) { return (behavior, text, scope) }
                }
            }
        }
        return nil
    }
}
