// @author ixxxxoooo
// Claude Code 模型映射:把 Claude Code 自带的几个模型槽位(默认/Opus/Sonnet/Haiku/子 Agent)
// 映射到任意提供商的任意模型。
//
// 做法:会话启动时,`ANTHROPIC_BASE_URL` 指向应用内的本机网关,各槽位环境变量设为固定别名
// (`oma-main` 等,刻意避开 opus/sonnet/haiku 字样以免触发 Claude Code 的按型号特判),
// 网关按别名把请求路由到真实的提供商与模型;真实密钥只在网关内存里,不进入 Claude Code 进程。
// 不改动用户的 `~/.claude/settings.json`。

import ACPKit
import CryptoKit
import Foundation
import OMLog
import ProviderProxyKit

/// Claude Code 的模型槽位。
public enum ModelSlot: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 默认(Claude Code 的 `default` 选项 / `ANTHROPIC_MODEL`)
    case main
    case opus
    case sonnet
    case haiku
    /// 子 Agent 使用的模型(`CLAUDE_CODE_SUBAGENT_MODEL`)
    case subagent

    public var id: String { rawValue }

    /// 网关里的模型别名(Claude Code 请求体 `model` 字段的值)。
    public var alias: String {
        switch self {
        case .main: "oma-main"
        case .opus: "oma-large"
        case .sonnet: "oma-medium"
        case .haiku: "oma-small"
        case .subagent: "oma-sub"
        }
    }

    /// 对应的 Claude Code 环境变量。
    public var modelEnvKey: String {
        switch self {
        case .main: "ANTHROPIC_MODEL"
        case .opus: "ANTHROPIC_DEFAULT_OPUS_MODEL"
        case .sonnet: "ANTHROPIC_DEFAULT_SONNET_MODEL"
        case .haiku: "ANTHROPIC_DEFAULT_HAIKU_MODEL"
        case .subagent: "CLAUDE_CODE_SUBAGENT_MODEL"
        }
    }

    /// 模型选择器里该槽位对应的 ACP 选项值(子 Agent 不出现在选择器里)。
    public var optionValue: String? {
        switch self {
        case .main: "default"
        case .opus: "opus"
        case .sonnet: "sonnet"
        case .haiku: "haiku"
        case .subagent: nil
        }
    }

    /// 界面展示名。
    public var title: String {
        switch self {
        case .main: String(localized: "默认")
        case .opus: "Opus"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        case .subagent: String(localized: "子 Agent")
        }
    }

    /// 说明文字。
    public var detail: String {
        switch self {
        case .main: String(localized: "新会话的默认模型;未单独设置的槽位也使用它")
        case .opus: String(localized: "选择 Opus 时使用(复杂任务)")
        case .sonnet: String(localized: "选择 Sonnet 时使用(日常编码)")
        case .haiku: String(localized: "选择 Haiku 时使用,Claude Code 的后台小任务也走它")
        case .subagent: String(localized: "子 Agent 使用的模型")
        }
    }

    /// 由 ACP 选项值反查槽位。
    /// - Parameter value: 选项值(`default` / `opus` / `sonnet` / `haiku`)
    public init?(optionValue value: String) {
        guard let slot = Self.allCases.first(where: { $0.optionValue == value }) else { return nil }
        self = slot
    }
}

/// 映射目标:某个提供商的某个模型。
public struct ModelTarget: Codable, Hashable, Sendable {
    public var providerId: String
    public var model: String

    public init(providerId: String, model: String) {
        self.providerId = providerId
        self.model = model
    }
}

/// 槽位 → 目标 的映射表(未设置的槽位不在表里)。
public struct ModelMapping: Codable, Equatable, Sendable {
    private var slots: [String: ModelTarget]

    public init(slots: [ModelSlot: ModelTarget] = [:]) {
        self.slots = Dictionary(uniqueKeysWithValues: slots.map { ($0.key.rawValue, $0.value) })
    }

    public init(from decoder: any Decoder) throws {
        slots = try decoder.singleValueContainer().decode([String: ModelTarget].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(slots)
    }

    /// 读写某个槽位(写入 nil 即清除)。
    public subscript(slot: ModelSlot) -> ModelTarget? {
        get { slots[slot.rawValue] }
        set { slots[slot.rawValue] = newValue }
    }

    /// 是否没有任何映射。
    public var isEmpty: Bool { slots.isEmpty }

    /// 删除所有指向某提供商的映射。
    /// - Parameter providerId: 提供商 ID
    public mutating func removeTargets(of providerId: String) {
        slots = slots.filter { $0.value.providerId != providerId }
    }
}

/// 映射到会话里、给界面展示用的模型信息。
public struct MappedModel: Equatable, Sendable {
    public var slot: ModelSlot
    public var providerId: String
    public var providerName: String
    /// 来源预设(用于推断厂商图标)
    public var presetId: String?
    /// 发给上游的真实模型 ID
    public var modelId: String
    /// 界面展示名(提供商里重命名过则取重命名)
    public var displayName: String
    /// 该模型的上下文窗口(token;模型级优先于提供商级,nil = 自动)
    public var contextWindow: Int?
}

/// 已解析的一个槽位目标(含密钥,禁止记录)。
struct ResolvedTarget: Sendable {
    var slot: ModelSlot
    var provider: ModelProvider
    var model: String
    var key: String

    var info: MappedModel {
        MappedModel(slot: slot, providerId: provider.id, providerName: provider.name, presetId: provider.presetId,
                    modelId: model, displayName: provider.displayName(forModel: model),
                    contextWindow: ProviderLaunch.contextWindow(of: self))
    }
}

/// 已解析、可直接用于启动会话的映射。
public struct ResolvedMapping: Sendable {
    /// 默认槽位(必有)
    var main: ResolvedTarget
    /// 其余已设置且有效的槽位
    var others: [ModelSlot: ResolvedTarget]
    /// 非致命问题(某槽位的提供商缺密钥/已停用等,该槽位退回默认槽位)
    public var warnings: [String]
    /// 用户的思考强度偏好(别名按真实模型继承强度,见 `MappedEffort`)
    public var effortPrefs = ClaudeEffortPrefs()

    /// 全部有效槽位(含默认)。
    var all: [ModelSlot: ResolvedTarget] {
        var result = others
        result[.main] = main
        return result
    }

    /// 给界面展示的映射信息。
    public var infos: [ModelSlot: MappedModel] { all.mapValues(\.info) }
}

/// 映射启动结果:会话 `_meta` 与展示信息。
public struct ActivatedMapping: Sendable {
    /// 会话 `_meta`(不含任何真实密钥)
    public var meta: JSONValue
    public var infos: [ModelSlot: MappedModel]
    public var warnings: [String]
    /// 本机网关地址(发送前探测可达性用)
    public var gatewayURL: URL
    /// 默认槽位的提供商 ID 与模型(日志用)
    public var mainProviderId: String
    public var mainModel: String
}

// MARK: - 启动环境

/// 生成 Claude Code 的会话级模型环境。
public enum ProviderLaunch {
    /// 交给 Claude Code 的占位令牌(网关不校验,真实密钥在网关内存里)。
    public static let placeholderToken = "oma-local-proxy"

    /// 映射会话必须清空的用户侧变量(其他后端、网关、旧模型名)。
    public static let clearedVariables = [
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_CUSTOM_HEADERS", "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_BASE_URL", "CLAUDE_AGENT_API_BASE_URL",
        "ANTHROPIC_CUSTOM_MODEL_OPTION", "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME", "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION",
        "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME", "ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION",
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
    ]

    /// 非密钥环境(放进 `settings.env`)。
    /// - Parameters:
    ///   - mapping: 已解析的映射
    ///   - gateway: 本机网关地址
    /// - Returns: 环境字典
    static func publicEnvironment(_ mapping: ResolvedMapping, gateway: URL) -> [String: String] {
        var env: [String: String] = [:]
        for name in clearedVariables { env[name] = "" }
        env["ANTHROPIC_BASE_URL"] = gateway.absoluteString
        let main = mapping.main
        // 未单独设置的槽位沿用默认槽位:别名与展示名都取默认槽位
        func target(_ slot: ModelSlot) -> (slot: ModelSlot, resolved: ResolvedTarget) {
            if let own = mapping.others[slot] { return (slot, own) }
            return (.main, main)
        }
        env[ModelSlot.main.modelEnvKey] = ModelSlot.main.alias
        for slot in [ModelSlot.opus, .sonnet, .haiku] {
            let effective = target(slot)
            env[slot.modelEnvKey] = effective.slot.alias
            env[slot.modelEnvKey + "_NAME"] = effective.resolved.provider.displayName(forModel: effective.resolved.model)
            env[slot.modelEnvKey + "_DESCRIPTION"] = effective.resolved.provider.name
        }
        if mapping.others[.subagent] != nil { env[ModelSlot.subagent.modelEnvKey] = ModelSlot.subagent.alias } else { env[ModelSlot.subagent.modelEnvKey] = "" }
        let provider = main.provider
        if let value = provider.maxOutputTokens, value > 0 { env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(value) }
        // 别名 oma-* 对 Claude Code 是未知模型,窗口默认 20 万:把真实窗口声明为模型窗口(压缩阈值走 settings,见 `sessionMeta`)
        if let value = contextWindow(of: main), value > 0 { env[SessionOptions.maxContextKey] = String(value) }
        if let value = nonEmpty(provider.effort) { env["CLAUDE_CODE_EFFORT_LEVEL"] = value }
        // 经网关的第三方模型不会返回服务端 auto 模式检查结果,关闭探测以免出现「分类器计费」警告
        env[NoticeFilter.autoModeServerKey] = "0"
        return env
    }

    /// 生成 `session/new|load|resume|fork` 的 `_meta`。
    /// - Parameters:
    ///   - mapping: 已解析的映射
    ///   - gateway: 本机网关地址
    /// - Returns: `_meta` JSON(只含占位令牌,不含真实密钥)
    static func sessionMeta(_ mapping: ResolvedMapping, gateway: URL) -> JSONValue {
        let publicEnv = publicEnvironment(mapping, gateway: gateway).mapValues(JSONValue.string)
        var fields: [String: JSONValue] = ["model": .string(ModelSlot.main.alias), "apiKeyHelper": .string(""), "env": .object(publicEnv)]
        // 自动压缩窗口放 settings(flag 层),不用最高优先级的环境变量,会话里的 /autocompact 仍可用
        if let window = contextWindow(of: mapping.main), SessionOptions.autoCompactRange.contains(window) {
            fields[SessionOptions.autoCompactSettingKey] = .int(window)
        }
        // 别名是 Claude Code 不认识的模型:按真实模型补上强度,否则一律落到未知模型默认的 high
        if let modelSettings = MappedEffort.modelSettings(mapping, prefs: mapping.effortPrefs) { fields["modelSettings"] = modelSettings }
        let settings: JSONValue = .object(fields)
        let secretEnv: JSONValue = .object(["ANTHROPIC_AUTH_TOKEN": .string(placeholderToken)])
        return .object(["claudeCode": .object(["options": .object(["settings": settings, "env": secretEnv])])])
    }

    /// 目标模型生效的上下文窗口:模型级优先于提供商级;未设置为 nil(自动)。
    static func contextWindow(of target: ResolvedTarget) -> Int? {
        target.provider.modelList.first(where: { $0.id == target.model })?.contextWindow ?? target.provider.contextWindow
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - 网关桥接

/// 提供商 → 会话的桥接:把映射注册到本机网关。
public enum ProviderBridge {
    /// 自有客户端标识(OpenCode 文档要求第三方客户端用自己的 UA,而不是伪装成官方客户端)。
    public static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "OhMyAgent/\(version)"
    }

    /// 由会话路由键派生稳定的 OpenCode 会话标识:同一对话恒定,不同对话互不相同(`ses_` + 24 位十六进制)。
    /// - Parameter sessionKey: 会话级路由键;空串时视为一次性请求,返回随机标识
    /// - Returns: `x-opencode-session` 的值
    public static func opencodeSessionID(for sessionKey: String) -> String {
        guard !sessionKey.isEmpty else { return "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24) }
        let digest = SHA256.hash(data: Data(sessionKey.utf8))
        return "ses_" + digest.map { String(format: "%02x", $0) }.joined().prefix(24)
    }

    /// OpenCode 兼容请求头:自有 UA + 稳定的 `x-opencode-session`(Go / Zen 端点据此路由与限流)。
    /// - Parameter sessionKey: 会话级路由键(见 `opencodeSessionID(for:)`)
    /// - Returns: 请求头字典
    public static func opencodeHeaders(sessionKey: String = "") -> [String: String] {
        ["User-Agent": userAgent, "x-opencode-session": opencodeSessionID(for: sessionKey)]
    }

    /// 为提供商构造代理路由(上游地址、密钥、附加头)。
    /// - Parameters:
    ///   - provider: 提供商
    ///   - key: 密钥(可空)
    /// - Returns: 路由;地址无效返回 nil
    public static func route(for provider: ModelProvider, key: String, sessionKey: String = "") -> ProxyRoute? {
        guard let url = provider.url else { return nil }
        var headers: [String: String] = [:]
        if provider.opencodeCompat == true { headers.merge(opencodeHeaders(sessionKey: sessionKey)) { _, new in new } }
        for line in ModelProvider.headerLines(provider.customHeaders ?? "") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        return ProxyRoute(upstreamBase: url, apiKey: key, extraHeaders: headers, usesAPIKeyHeader: provider.usesAPIKeyHeader == true)
    }

    /// 把一个已解析的槽位目标变成网关目标。
    static func target(for resolved: ResolvedTarget, sessionKey: String = "") -> ProxyTarget? {
        guard let route = route(for: resolved.provider, key: resolved.key, sessionKey: sessionKey) else { return nil }
        return ProxyTarget(wire: resolved.provider.isOpenAIProtocol ? .openAI : .anthropic, route: route, model: resolved.model,
                           label: "\(resolved.provider.id)/\(resolved.slot.rawValue)")
    }

    /// 把映射注册到本机网关并生成会话 `_meta`。
    /// - Parameters:
    ///   - mapping: 已解析的映射
    ///   - sessionKey: 会话级路由键(同一会话重连沿用同一令牌)
    ///   - proxy: 代理(测试可注入)
    /// - Returns: 会话元数据与展示信息
    /// - Throws: 地址无效或网关启动失败
    public static func activate(_ mapping: ResolvedMapping, sessionKey: String, proxy: ProviderProxy = .shared) async throws -> ActivatedMapping {
        var targets: [String: ProxyTarget] = [:]
        for (slot, resolved) in mapping.all {
            guard let target = target(for: resolved, sessionKey: sessionKey) else { throw ModelProvider.ValidationError.invalidBaseURL }
            targets[slot.alias] = target
        }
        guard let fallback = targets[ModelSlot.main.alias] else { throw ModelProvider.ValidationError.invalidBaseURL }
        let url = try await proxy.register(key: sessionKey, targets: targets, fallback: fallback)
        return ActivatedMapping(meta: ProviderLaunch.sessionMeta(mapping, gateway: url), infos: mapping.infos, warnings: mapping.warnings,
                                gatewayURL: url, mainProviderId: mapping.main.provider.id, mainModel: mapping.main.model)
    }

    /// 注销会话的网关路由。
    /// - Parameters:
    ///   - sessionKey: 会话级路由键
    ///   - proxy: 代理(测试可注入)
    public static func deactivate(sessionKey: String, proxy: ProviderProxy = .shared) async {
        await proxy.unregister(key: sessionKey)
    }
}
