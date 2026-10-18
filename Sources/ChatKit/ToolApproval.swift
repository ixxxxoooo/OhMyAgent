// @author ixxxxoooo
// 工具审批策略(对照 Cursor 的「每次询问 / 允许列表 / 自动运行」三档):终端命令与浏览器访问共用一套。
// 纯逻辑,无 UI;设置页与 `SessionModel.awaitPermission` 共同使用。

import ACPKit
import Foundation

/// 审批档位。
public enum ToolApprovalMode: String, CaseIterable, Sendable, Identifiable {
    /// 每次都询问
    case ask
    /// 命中允许列表自动放行,其余询问
    case allowlist
    /// 全部自动放行
    case auto

    public var id: String { rawValue }
}

/// 审批领域。
public enum ToolApprovalDomain: String, CaseIterable, Sendable {
    case terminal
    case browser

    /// 档位的偏好键。
    public var modeKey: String { "approval.\(rawValue).mode" }
    /// 允许列表的偏好键(每行一条)。
    public var listKey: String { "approval.\(rawValue).allowlist" }
}

/// 一个领域的审批策略。
public struct ToolApprovalPolicy: Sendable, Equatable {
    /// 决定。
    public enum Decision: Sendable, Equatable {
        case ask
        case allow
    }

    public var mode: ToolApprovalMode
    public var allowlist: [String]

    public init(mode: ToolApprovalMode = .ask, allowlist: [String] = []) {
        self.mode = mode
        self.allowlist = allowlist
    }

    /// 从偏好读取。
    /// - Parameters:
    ///   - domain: 领域
    ///   - defaults: 偏好存储
    public static func load(_ domain: ToolApprovalDomain, _ defaults: UserDefaults = .standard) -> ToolApprovalPolicy {
        let mode = ToolApprovalMode(rawValue: defaults.string(forKey: domain.modeKey) ?? "") ?? .ask
        return ToolApprovalPolicy(mode: mode, allowlist: parseList(defaults.string(forKey: domain.listKey) ?? ""))
    }

    /// 保存允许列表。
    /// - Parameters:
    ///   - list: 条目
    ///   - domain: 领域
    ///   - defaults: 偏好存储
    public static func saveList(_ list: [String], for domain: ToolApprovalDomain, _ defaults: UserDefaults = .standard) {
        defaults.set(list.joined(separator: "\n"), forKey: domain.listKey)
    }

    /// 把多行文本解析为去重、去空的条目。
    public static func parseList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 决定一次操作是否可自动放行。
    /// - Parameters:
    ///   - subject: 终端为命令行,浏览器为 URL
    ///   - domain: 领域
    /// - Returns: `.allow` 表示无需询问
    public func decide(subject: String, domain: ToolApprovalDomain) -> Decision {
        switch mode {
        case .ask: return .ask
        case .auto: return .allow
        case .allowlist:
            let hit = allowlist.contains { entry in
                switch domain {
                case .terminal: Self.matchesCommand(entry: entry, command: subject)
                case .browser: Self.matchesOrigin(entry: entry, url: subject)
                }
            }
            return hit ? .allow : .ask
        }
    }

    /// 命令是否含串联/重定向/替换,这类命令不能凭前缀放行(`git status; rm -rf ~` 不应命中 `git status`)。
    static func isCompound(_ command: String) -> Bool {
        command.contains(where: { ";|&<>\n`".contains($0) }) || command.contains("$(")
    }

    /// 命令是否命中条目:精确相等、`条目 + 空格` 前缀,或以 `*` 结尾的前缀。
    /// - Parameters:
    ///   - entry: 允许列表条目
    ///   - command: 命令行
    public static func matchesCommand(entry: String, command: String) -> Bool {
        let command = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        let entry = entry.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        guard !command.isEmpty, !entry.isEmpty, !isCompound(command) else { return false }
        if entry.hasSuffix("*") {
            let prefix = String(entry.dropLast()).trimmingCharacters(in: .whitespaces)
            return !prefix.isEmpty && (command == prefix || command.hasPrefix(prefix + " ") || command.hasPrefix(String(entry.dropLast())))
        }
        return command == entry || command.hasPrefix(entry + " ")
    }

    /// URL 是否命中条目:`https://a.com`(精确来源)、`a.com`(主机)、`*.a.com`(含子域)。
    /// - Parameters:
    ///   - entry: 允许列表条目
    ///   - url: 被访问的 URL
    public static func matchesOrigin(entry: String, url: String) -> Bool {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased() else { return false }
        let entry = entry.lowercased()
        if entry.contains("://") {
            guard let allowed = URLComponents(string: entry), let allowedHost = allowed.host else { return false }
            return allowed.scheme == components.scheme && allowedHost == host && (allowed.port == nil || allowed.port == components.port)
        }
        if entry.hasPrefix("*.") {
            let suffix = String(entry.dropFirst(1))
            return host.hasSuffix(suffix) || host == String(entry.dropFirst(2))
        }
        return host == entry
    }

    /// 从权限请求里提取审批领域与对象。
    /// - Parameters:
    ///   - call: 工具调用(权限请求里的 toolCall)
    ///   - browserPageURL: 浏览器当前页面的地址;点击、输入、截图等没有 `url` 参数的浏览器动作以它作为审批对象
    /// - Returns: 领域与对象(命令/URL);无法识别时为 nil(一律询问)
    public static func subject(of call: ToolCall, browserPageURL: String? = nil) -> (domain: ToolApprovalDomain, subject: String)? {
        if call.kind == .execute, let command = call.rawInput?["command"]?.stringValue, !command.isEmpty {
            return (.terminal, command)
        }
        if let name = call.name, name.contains("browser_") {
            if let url = call.rawInput?["url"]?.stringValue, !url.isEmpty { return (.browser, url) }
            // 没有 url 的动作(点击/输入/截图/控制台…):按当前页面算。自动运行档不看对象,允许列表档要求当前页面命中。
            return (.browser, browserPageURL ?? "")
        }
        return nil
    }
}
