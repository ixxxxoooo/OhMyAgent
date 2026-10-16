// @author ixxxxoooo
// 客户端级会话选项:网络代理/超时、追加系统提示词、是否加载 CLAUDE.md。
// 这些选项在创建/恢复会话时合并进 ACP `_meta`(`claudeCode.options.env` 与 `systemPrompt.append`)。

import ACPKit
import Foundation

/// 网络代理模式。
public enum ProxyMode: String, CaseIterable, Sendable, Identifiable {
    /// 沿用系统/登录 shell 环境(不注入任何变量)
    case system
    /// 强制直连(清空代理变量)
    case off
    case http
    case socks5

    public var id: String { rawValue }
}

/// 发送键。
public enum SendKey: String, Sendable, CaseIterable, Identifiable {
    /// Return 发送,Shift+Return 换行
    case enter
    /// ⌘Return 发送,Return 换行
    case commandEnter

    public var id: String { rawValue }
}

/// Agent 运行中再发送消息的默认行为。
public enum RunningSendMode: String, Sendable, CaseIterable, Identifiable {
    /// 作为引导注入当前轮次(Agent 不支持时排队)
    case steer
    /// 排到本轮结束后发送
    case queue

    public var id: String { rawValue }
}

/// 聊天内容宽度档位。
public enum ChatWidth: String, Sendable, CaseIterable, Identifiable {
    case narrow, standard, wide, full

    public var id: String { rawValue }

    /// 最大宽度(点);`full` 为不限制。
    public var points: CGFloat {
        switch self {
        case .narrow: return 680
        case .standard: return 820
        case .wide: return 1000
        case .full: return .infinity
        }
    }
}

/// 一次会话创建所需的客户端选项快照。
public struct SessionOptions: Equatable, Sendable {
    public var proxyMode: ProxyMode = .system
    /// 代理地址 `host:port`(`http`/`socks5` 模式使用)
    public var proxyAddress = ""
    /// 请求超时(秒);0 表示使用 Claude Code 默认值
    public var timeoutSeconds = 0
    /// 追加到系统提示词末尾的文本
    public var appendPrompt = ""
    /// 是否加载 CLAUDE.md(记忆文件)
    public var loadClaudeMemory = true

    public init() {}

    /// 从偏好读取当前选项。
    /// - Parameter defaults: 偏好存储
    public init(defaults: UserDefaults) {
        proxyMode = ProxyMode(rawValue: defaults.string(forKey: ClientPrefs.Key.proxyMode) ?? "") ?? .system
        proxyAddress = defaults.string(forKey: ClientPrefs.Key.proxyAddress) ?? ""
        timeoutSeconds = max(defaults.integer(forKey: ClientPrefs.Key.requestTimeout), 0)
        appendPrompt = defaults.string(forKey: ClientPrefs.Key.appendPrompt) ?? ""
        loadClaudeMemory = defaults.object(forKey: ClientPrefs.Key.loadClaudeMemory) as? Bool ?? true
    }

    /// 规范化后的代理 URL;模式为 `system`/`off` 或地址无效时返回 nil。
    public var proxyURL: String? {
        let address = proxyAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, proxyMode == .http || proxyMode == .socks5 else { return nil }
        let scheme = proxyMode == .socks5 ? "socks5" : "http"
        if address.contains("://") { return address }
        return "\(scheme)://\(address)"
    }

    /// 需要注入 Claude 进程的环境变量。
    public var environment: [String: String] {
        var env: [String: String] = [:]
        switch proxyMode {
        case .system:
            break
        case .off:
            for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] { env[name] = "" }
            env["NO_PROXY"] = "*"
        case .http, .socks5:
            if let url = proxyURL {
                if proxyMode == .http {
                    for name in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] { env[name] = url }
                } else {
                    env["ALL_PROXY"] = url
                    env["all_proxy"] = url
                }
            }
        }
        if timeoutSeconds > 0 { env["API_TIMEOUT_MS"] = String(timeoutSeconds * 1000) }
        if !loadClaudeMemory { env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1" }
        return env
    }

    /// 追加提示词(去除首尾空白;为空返回 nil)。
    public var trimmedPrompt: String? {
        let text = appendPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 是否有任何选项需要写入 `_meta`。
    public var isDefault: Bool { environment.isEmpty && trimmedPrompt == nil }

    /// 把选项合并进已有的会话 `_meta`(如模型提供商生成的),不覆盖提供商已设置的变量。
    /// - Parameter base: 已有 `_meta`(可为 nil)
    /// - Returns: 合并后的 `_meta`;无任何选项且 `base` 为 nil 时返回 nil
    public func merged(into base: JSONValue?) -> JSONValue? {
        guard !isDefault else { return base }
        var root: [String: JSONValue] = [:]
        if case .object(let object)? = base { root = object }

        var claudeCode: [String: JSONValue] = [:]
        if case .object(let object)? = root["claudeCode"] { claudeCode = object }
        var options: [String: JSONValue] = [:]
        if case .object(let object)? = claudeCode["options"] { options = object }
        var env: [String: JSONValue] = [:]
        if case .object(let object)? = options["env"] { env = object }
        // 提供商/用户已显式设置的变量优先
        for (key, value) in environment where env[key] == nil { env[key] = .string(value) }
        if !env.isEmpty { options["env"] = .object(env) }
        if !options.isEmpty { claudeCode["options"] = .object(options) }
        if !claudeCode.isEmpty { root["claudeCode"] = .object(claudeCode) }

        if let prompt = trimmedPrompt, root["systemPrompt"] == nil {
            root["systemPrompt"] = .object(["append": .string(prompt)])
        }
        return .object(root)
    }
}
