// @author ixxxxoooo
// 模型提供商:提供商只负责「地址 + 协议 + 密钥 + 模型清单」;哪个 Claude Code 槽位用哪个模型由
// `ModelMapping`(见 ModelMapping.swift)决定。会话启动时经 ACP 的 `_meta.claudeCode.options`
// 把本机网关地址与槽位别名交给 Claude Code,不改动用户的 `~/.claude/settings.json`。
//
// 要点:
// - 非密钥部分放进 `settings.env`(程序化设置层,优先于用户/项目设置);
// - 真实密钥只在应用内网关的内存里,Claude Code 只拿到占位令牌;
// - Anthropic 协议厂商由网关透传,OpenAI 协议厂商由网关转换。

import ACPKit
import Foundation
import ProviderProxyKit
import OMLog

/// 模型提供商配置(不含密钥)。
public struct ModelProvider: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Anthropic 协议端点(如 `https://api.deepseek.com/anthropic`)
    public var baseURL: String
    /// 默认模型(新建映射、测试连接时的缺省模型)
    public var model: String
    /// 旧版各角色模型(仅用于迁移到「模型映射」,界面不再编辑)
    public var opusModel: String?
    public var sonnetModel: String?
    public var haikuModel: String?
    /// 来源预设(仅用于界面展示)
    public var presetId: String?
    /// 最大输出 token(对应 `CLAUDE_CODE_MAX_OUTPUT_TOKENS`;nil 使用默认)
    public var maxOutputTokens: Int?
    /// 思考强度(`low` / `medium` / `high`,对应 `CLAUDE_CODE_EFFORT_LEVEL`;nil 使用默认)
    public var effort: String?
    /// 自定义请求头,每行一个 `Name: Value`(对应 `ANTHROPIC_CUSTOM_HEADERS`,可能含密钥,只进进程环境)
    public var customHeaders: String?
    /// 上下文窗口(token,对应 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`;nil 使用默认)
    public var contextWindow: Int?
    /// 可选模型列表(从 `/v1/models` 获取或手动维护,用于输入框的模型菜单)
    public var availableModels: [String]?
    /// 鉴权头:`false`(默认)用 `Authorization: Bearer`(ANTHROPIC_AUTH_TOKEN);`true` 用 `x-api-key`(ANTHROPIC_API_KEY,Anthropic 官方 API)
    public var usesAPIKeyHeader: Bool?
    /// API 协议;nil 视为 Anthropic(旧数据)
    public var protocolKind: ProviderProtocol?
    /// 模型清单(可重命名、可启停);nil 时由 `model` + `availableModels` 推导
    public var models: [ProviderModel]?
    /// 在设置页与输入框菜单中是否启用;nil 视为启用
    public var enabled: Bool?
    /// 密钥是否可不填(Ollama / LM Studio / OpenCode 免费模型等)
    public var keyOptional: Bool?
    /// OpenCode 兼容:请求带上 OpenCode 客户端的 UA 与会话头(仅 OpenAI 协议经代理时生效)
    public var opencodeCompat: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, model, opusModel, sonnetModel, haikuModel, presetId, maxOutputTokens, effort, customHeaders
        case contextWindow, availableModels, usesAPIKeyHeader, models, enabled, keyOptional, opencodeCompat
        case protocolKind = "protocol"
    }

    public init(id: String, name: String, baseURL: String, model: String, opusModel: String? = nil, sonnetModel: String? = nil, haikuModel: String? = nil, presetId: String? = nil,
                maxOutputTokens: Int? = nil, effort: String? = nil, customHeaders: String? = nil, contextWindow: Int? = nil, availableModels: [String]? = nil, usesAPIKeyHeader: Bool? = nil,
                protocolKind: ProviderProtocol? = nil, models: [ProviderModel]? = nil, enabled: Bool? = nil, keyOptional: Bool? = nil, opencodeCompat: Bool? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.opusModel = opusModel
        self.sonnetModel = sonnetModel
        self.haikuModel = haikuModel
        self.presetId = presetId
        self.maxOutputTokens = maxOutputTokens
        self.effort = effort
        self.customHeaders = customHeaders
        self.contextWindow = contextWindow
        self.availableModels = availableModels
        self.usesAPIKeyHeader = usesAPIKeyHeader
        self.protocolKind = protocolKind
        self.models = models
        self.enabled = enabled
        self.keyOptional = keyOptional
        self.opencodeCompat = opencodeCompat
    }

    /// 配置校验错误。
    public enum ValidationError: Error, LocalizedError, Equatable {
        case emptyName, invalidBaseURL, emptyModel, invalidNumber(String), invalidEffort, invalidHeaders
        public var errorDescription: String? {
            switch self {
            case .invalidNumber(let field): String(localized: "\(field) 必须是正整数")
            case .invalidEffort: String(localized: "思考强度只能是 low / medium / high")
            case .invalidHeaders: String(localized: "自定义请求头每行必须是「Name: Value」")
            case .emptyName: String(localized: "名称不能为空")
            case .invalidBaseURL: String(localized: "地址必须是 http(s) 绝对地址")
            case .emptyModel: String(localized: "模型不能为空")
            }
        }
    }

    /// 校验字段合法性。
    /// - Throws: `ValidationError`
    public func validate() throws {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.emptyName }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { throw ValidationError.invalidBaseURL }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.emptyModel }
        if let maxOutputTokens, maxOutputTokens <= 0 { throw ValidationError.invalidNumber(String(localized: "最大输出 token")) }
        if let contextWindow, contextWindow <= 0 { throw ValidationError.invalidNumber(String(localized: "上下文窗口")) }
        if let effort, !effort.isEmpty, !["low", "medium", "high"].contains(effort) { throw ValidationError.invalidEffort }
        if let customHeaders, !Self.headerLines(customHeaders).allSatisfy({ $0.contains(":") && !($0.split(separator: ":").first ?? "").trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw ValidationError.invalidHeaders
        }
    }

    /// 自定义请求头的有效行(去空行与首尾空白)。
    static func headerLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 规范化后的地址(去空白与末尾斜杠)。
    public var normalizedBaseURL: String {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// 可探测的地址对象。
    public var url: URL? { URL(string: normalizedBaseURL) }
}

/// 常用提供商预设(Anthropic 兼容端点直连;OpenAI 协议端点经本地协议代理)。
public struct ProviderPreset: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var models: [String]
    public var hint: String
    /// 协议(默认 Anthropic)
    public var protocolKind: ProviderProtocol = .anthropic
    /// 密钥可不填
    public var keyOptional = false
    /// 需要 OpenCode 兼容请求头
    public var opencodeCompat = false
    /// 使用 x-api-key 头鉴权(Anthropic 官方、OpenCode Zen 的 Anthropic 端点)
    public var apiKeyHeader = false

    /// 默认模型(列表第一个)。
    public var defaultModel: String { models.first ?? "" }

    /// 预设列表。
    public static let all: [ProviderPreset] = [
        ProviderPreset(id: "anthropic", name: String(localized: "Anthropic 官方"), baseURL: "https://api.anthropic.com", models: ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"], hint: String(localized: "官方 API(按量计费),使用 x-api-key 鉴权;需要自己的 API Key,不使用 claude 登录凭据。"), apiKeyHeader: true),
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/anthropic", models: ["deepseek-chat", "deepseek-reasoner"], hint: String(localized: "官方原生兼容 Anthropic 协议,国内直连。注意 `/v1` 是 OpenAI 协议端点,这里必须用 `/anthropic`。")),
        ProviderPreset(id: "glm", name: String(localized: "智谱 GLM"), baseURL: "https://open.bigmodel.cn/api/anthropic", models: ["glm-4.6", "glm-4.5", "glm-4.5-air"], hint: String(localized: "智谱开放平台 Claude API 兼容端点")),
        ProviderPreset(id: "kimi", name: "Kimi(Moonshot)", baseURL: "https://api.moonshot.cn/anthropic", models: ["kimi-k2-turbo-preview", "kimi-k2-0905-preview"], hint: String(localized: "海外可改用 api.moonshot.ai/anthropic")),
        ProviderPreset(id: "minimax", name: "MiniMax", baseURL: "https://api.minimaxi.com/anthropic", models: ["MiniMax-M2"], hint: String(localized: "海外可改用 api.minimax.io/anthropic")),
        ProviderPreset(id: "qwen", name: String(localized: "阿里云百炼(Qwen)"), baseURL: "https://dashscope.aliyuncs.com/apps/anthropic", models: ["qwen3-coder-plus", "qwen3-coder-flash"], hint: String(localized: "Coding Plan 用户端点略有不同,可手动修改")),
        ProviderPreset(id: "opencode", name: "OpenCode Zen", baseURL: "https://opencode.ai/zen", models: ["claude-sonnet-4-5", "qwen3-coder", "kimi-k2"], hint: String(localized: "OpenCode Zen 网关的 Anthropic 兼容端点(按量付费模型);免费模型请改用「OpenCode 免费模型(Go)」或「OpenCode Go」。"), opencodeCompat: true, apiKeyHeader: true),
        ProviderPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", models: ["gpt-4.1", "gpt-4o", "o4-mini"], hint: String(localized: "OpenAI 协议:经本机内置的协议代理转换后交给 Claude Code。"), protocolKind: .openai),
        ProviderPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", models: ["anthropic/claude-sonnet-4.5", "openai/gpt-4.1", "google/gemini-2.5-pro"], hint: String(localized: "聚合多家模型的 OpenAI 协议网关;模型名形如 厂商/模型。"), protocolKind: .openai),
        ProviderPreset(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", models: ["gemini-2.5-pro", "gemini-2.5-flash"], hint: String(localized: "Gemini 的 OpenAI 兼容端点,使用 Google AI Studio 的 API Key。"), protocolKind: .openai),
        ProviderPreset(id: "ollama", name: "Ollama", baseURL: "http://localhost:11434/v1", models: ["qwen3-coder"], hint: String(localized: "本机 Ollama 的 OpenAI 兼容端点,无需密钥;模型需要支持工具调用。"), protocolKind: .openai, keyOptional: true),
        ProviderPreset(id: "lmstudio", name: "LM Studio", baseURL: "http://localhost:1234/v1", models: ["local-model"], hint: String(localized: "本机 LM Studio 的 OpenAI 兼容端点,无需密钥;请在 LM Studio 中先加载模型。"), protocolKind: .openai, keyOptional: true),
        ProviderPreset(id: "opencode-go", name: "OpenCode Go", baseURL: "https://opencode.ai/zen/go/v1", models: ["glm-4.6"], hint: String(localized: "OpenCode Go 订阅的 OpenAI 协议端点;模型名以其控制台为准,可用「获取模型列表」同步。"), protocolKind: .openai, opencodeCompat: true),
        ProviderPreset(id: "opencode-free", name: String(localized: "OpenCode 免费模型(Go)"), baseURL: "https://opencode.ai/zen/go/v1", models: ["longcat-2.5-preview-free"], hint: String(localized: "OpenCode 的限时免费模型(LongCat、Cat Jam 等)走 Go 端点,需要 OpenCode 账号的 API Key;Zen 端点的免费层仅限官方客户端。"), protocolKind: .openai, opencodeCompat: true),
    ]

    /// 由预设生成提供商。
    public func makeProvider() -> ModelProvider {
        ModelProvider(id: id, name: name, baseURL: baseURL, model: defaultModel, presetId: id, usesAPIKeyHeader: apiKeyHeader ? true : nil,
                      protocolKind: protocolKind == .openai ? .openai : nil, models: models.map { ProviderModel(id: $0) },
                      keyOptional: keyOptional ? true : nil, opencodeCompat: opencodeCompat ? true : nil)
    }
}

/// 提供商文件快照(磁盘格式)。
public struct ProviderSnapshot: Codable, Sendable, Equatable {
    /// Claude Code 槽位 → 提供商模型 的映射
    public var mapping: ModelMapping
    public var providers: [ModelProvider]
    /// 旧版「全局默认提供商」(只读取用于迁移,不再写出)
    var legacyActive: String?
    /// 是否启用映射。false 时保留映射内容但不注入网关,Claude Code 走 ~/.claude 与官方登录(旧文件无此字段时为 true)
    public var useMapping: Bool

    public init(mapping: ModelMapping = ModelMapping(), providers: [ModelProvider] = [], useMapping: Bool = true) {
        self.mapping = mapping
        self.providers = providers
        self.useMapping = useMapping
    }

    private enum CodingKeys: String, CodingKey { case mapping, providers, active, useMapping }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mapping = try container.decodeIfPresent(ModelMapping.self, forKey: .mapping) ?? ModelMapping()
        providers = try container.decodeIfPresent([ModelProvider].self, forKey: .providers) ?? []
        legacyActive = try container.decodeIfPresent(String.self, forKey: .active)
        useMapping = try container.decodeIfPresent(Bool.self, forKey: .useMapping) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mapping, forKey: .mapping)
        try container.encode(providers, forKey: .providers)
        try container.encode(useMapping, forKey: .useMapping)
    }

    /// 旧数据迁移:映射为空且存在旧的全局默认提供商时,把它(及其 Opus/Sonnet/Haiku 角色模型)转成映射。
    /// - Returns: 迁移后的副本
    func migratedMapping() -> ProviderSnapshot {
        var copy = self
        defer { copy.legacyActive = nil }
        guard copy.mapping.isEmpty, let id = legacyActive,
              let provider = copy.providers.first(where: { $0.id == id }), provider.isEnabled, !provider.model.isEmpty else { return copy }
        copy.mapping[.main] = ModelTarget(providerId: id, model: provider.model)
        for (slot, role) in [(ModelSlot.opus, provider.opusModel), (.sonnet, provider.sonnetModel), (.haiku, provider.haikuModel)] {
            if let role = ProviderLaunch.nonEmpty(role), role != provider.model { copy.mapping[slot] = ModelTarget(providerId: id, model: role) }
        }
        return copy
    }
}

/// 提供商与密钥的磁盘存取(纯函数式,可在后台线程调用)。
public enum ProviderStorage {
    /// 默认目录:`~/Library/Application Support/OhMyAgent`。
    public static var defaultDirectory: URL {
        AppEnv.supportDirectory
    }

    static func providersURL(_ directory: URL) -> URL { directory.appendingPathComponent("providers.json") }
    static func keysURL(_ directory: URL) -> URL { directory.appendingPathComponent("provider-keys.json") }
    /// 默认密钥文件的显示路径(家目录缩写为 `~`;开发版指向 `OhMyAgent-Dev`)。
    public static var keysDisplayPath: String { (keysURL(defaultDirectory).path as NSString).abbreviatingWithTildeInPath }

    /// 读取提供商配置(缺失或损坏返回空)。
    public static func load(directory: URL = defaultDirectory) -> ProviderSnapshot {
        guard let data = try? Data(contentsOf: providersURL(directory)) else { return ProviderSnapshot() }
        do {
            var snapshot = try JSONDecoder().decode(ProviderSnapshot.self, from: data)
            snapshot.providers = snapshot.providers.map { $0.migrated() }
            return snapshot.migratedMapping()
        } catch {
            Log.agent.error("providers.json 解析失败", error: error)
            return ProviderSnapshot()
        }
    }

    /// 写入提供商配置。
    /// - Throws: 编码或写盘错误
    public static func save(_ snapshot: ProviderSnapshot, directory: URL = defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: providersURL(directory), options: .atomic)
    }

    /// 读取整个密钥文件(缺失或损坏返回空)。
    static func loadKeys(directory: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: keysURL(directory)),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    /// 从已读入的密钥表取某提供商的密钥(环境变量 `OMA_PROVIDER_KEY` 优先)。
    static func key(for id: String, keys: [String: String], environment: [String: String]) -> String? {
        if let value = environment["OMA_PROVIDER_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        guard let value = keys[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// 读取密钥:环境变量 `OMA_PROVIDER_KEY` 优先(调试用),其次密钥文件。
    public static func key(for id: String, directory: URL = defaultDirectory, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let value = environment["OMA_PROVIDER_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        guard let data = try? Data(contentsOf: keysURL(directory)),
              let map = try? JSONDecoder().decode([String: String].self, from: data),
              let value = map[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// 是否设置了调试用的 `OMA_PROVIDER_KEY` 环境变量(对所有提供商生效)。
    public static var hasEnvironmentKey: Bool {
        !(ProcessInfo.processInfo.environment["OMA_PROVIDER_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    /// 已保存密钥的提供商 ID 集合(只读一次密钥文件,不返回密钥本身)。
    /// - Parameter directory: 存储目录
    /// - Returns: 有非空密钥的提供商 ID
    public static func keyedIds(directory: URL = defaultDirectory) -> Set<String> {
        guard let data = try? Data(contentsOf: keysURL(directory)),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [] }
        return Set(map.compactMap { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.key })
    }

    /// 写入或删除密钥(权限 0600)。
    /// 已有密钥文件读取或解析失败时直接抛错、不写盘,避免把其他提供商的密钥一并抹掉。
    /// - Parameters:
    ///   - key: 密钥,空串表示删除
    ///   - id: 提供商 ID
    /// - Throws: 读取/解析已有密钥文件或写盘错误
    public static func setKey(_ key: String, for id: String, directory: URL = defaultDirectory) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = keysURL(directory)
        var map: [String: String] = [:]
        if fm.fileExists(atPath: url.path) {
            map = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { map.removeValue(forKey: id) } else { map[id] = trimmed }
        try writePrivately(JSONEncoder().encode(map), to: url)
    }

    /// 以 0600 权限原子写入:先在同目录创建 0600 临时文件再改名替换,密钥不会有对其他用户可读的窗口期。
    /// - Parameters:
    ///   - data: 内容
    ///   - url: 目标文件
    /// - Throws: 创建或改名失败
    static func writePrivately(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// 解析当前的模型映射。
    /// - Returns: 默认槽位已设置且有效返回 `ResolvedMapping`;未设置映射返回 nil(使用 ~/.claude 的系统默认)
    /// - Throws: 默认槽位的提供商缺密钥/已停用/配置无效时抛 `ResolveError`(其他槽位的问题只产生警告并退回默认槽位)
    static func resolveMapping(directory: URL = defaultDirectory, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ResolvedMapping? {
        let snapshot = load(directory: directory)
        guard snapshot.useMapping, let mainTarget = snapshot.mapping[.main] else { return nil }
        let keys = loadKeys(directory: directory)

        func resolve(_ slot: ModelSlot, _ target: ModelTarget) throws -> ResolvedTarget {
            guard let provider = snapshot.providers.first(where: { $0.id == target.providerId }) else {
                throw ResolveError.invalid(target.providerId, String(localized: "提供商已被删除"))
            }
            guard provider.isEnabled else { throw ResolveError.disabled(provider.name) }
            guard !target.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw ResolveError.invalid(provider.name, String(localized: "模型不能为空")) }
            do { try provider.validate() } catch { throw ResolveError.invalid(provider.name, error.localizedDescription) }
            let secret = key(for: provider.id, keys: keys, environment: environment)
            if secret == nil, provider.requiresKey { throw ResolveError.missingKey(provider.name) }
            return ResolvedTarget(slot: slot, provider: provider, model: target.model, key: secret ?? "")
        }

        let main = try resolve(.main, mainTarget)
        var others: [ModelSlot: ResolvedTarget] = [:]
        var warnings: [String] = []
        for slot in ModelSlot.allCases where slot != .main {
            guard let target = snapshot.mapping[slot] else { continue }
            do { others[slot] = try resolve(slot, target) } catch {
                warnings.append(String(localized: "「\(slot.title)」槽位不可用,已改用默认槽位:\(error.localizedDescription)"))
            }
        }
        return ResolvedMapping(main: main, others: others, warnings: warnings)
    }

    /// 已配置的映射展示信息(不论是否启用,不含密钥,用于输入框同时列出「自定义映射」分组)。
    /// 未单独设置的槽位沿用默认槽位;默认槽位未设置或提供商已删除则返回空。
    /// - Parameter directory: 存储目录
    /// - Returns: 槽位 → 展示信息(仅含出现在模型选择器里的槽位)
    public static func configuredInfos(directory: URL = defaultDirectory) -> [ModelSlot: MappedModel] {
        let snapshot = load(directory: directory)
        guard let main = snapshot.mapping[.main] else { return [:] }
        var result: [ModelSlot: MappedModel] = [:]
        for slot in ModelSlot.allCases where slot.optionValue != nil {
            let target = snapshot.mapping[slot] ?? main
            guard let provider = snapshot.providers.first(where: { $0.id == target.providerId }), !target.model.isEmpty else { continue }
            result[slot] = MappedModel(slot: slot, providerId: provider.id, providerName: provider.name, presetId: provider.presetId,
                                       modelId: target.model, displayName: provider.displayName(forModel: target.model),
                                       contextWindow: provider.modelList.first(where: { $0.id == target.model })?.contextWindow ?? provider.contextWindow)
        }
        return result
    }

    /// 切换是否启用映射(读-改-写 providers.json,映射内容保持不变)。
    /// - Parameters:
    ///   - enabled: 是否启用
    ///   - directory: 存储目录
    /// - Throws: 写盘错误
    public static func setUseMapping(_ enabled: Bool, directory: URL = defaultDirectory) throws {
        var snapshot = load(directory: directory)
        guard snapshot.useMapping != enabled else { return }
        snapshot.useMapping = enabled
        try save(snapshot, directory: directory)
    }

    /// 设置某个提供商下某个模型的上下文窗口(读-改-写 providers.json;nil 清除,恢复「自动」)。
    /// - Parameters:
    ///   - tokens: 窗口 token 数(0 = 显式「自动」,会覆盖提供商级窗口与全局偏好;nil = 清除记忆,沿用上一级)
    ///   - model: 模型 ID
    ///   - providerId: 提供商 ID
    ///   - directory: 存储目录
    /// - Throws: 写盘错误;提供商不存在时静默忽略
    public static func setModelContextWindow(_ tokens: Int?, model: String, providerId: String, directory: URL = defaultDirectory) throws {
        guard !model.isEmpty else { return }
        var snapshot = load(directory: directory)
        guard let index = snapshot.providers.firstIndex(where: { $0.id == providerId }) else { return }
        var list = snapshot.providers[index].modelList
        if let at = list.firstIndex(where: { $0.id == model }) {
            list[at].contextWindow = tokens
        } else {
            list.append(ProviderModel(id: model, contextWindow: tokens))
        }
        snapshot.providers[index].models = list
        snapshot.providers[index].availableModels = nil
        try save(snapshot, directory: directory)
    }

    /// 解析错误(会话会据此提示并回退到系统默认)。
    public enum ResolveError: Error, LocalizedError, Equatable {
        case missingKey(String)
        case invalid(String, String)
        case disabled(String)
        public var errorDescription: String? {
            switch self {
            case .disabled(let name): String(localized: "模型提供商「\(name)」已停用:请在 设置 → 模型提供商 中启用,或调整 Claude Code 模型映射。已暂时使用 ~/.claude 的默认配置。")
            case .missingKey(let name): String(localized: "模型提供商「\(name)」未设置 API Key:请在 设置 → 模型提供商 中填写。已暂时使用 ~/.claude 的默认配置。")
            case .invalid(let name, let reason): String(localized: "模型提供商「\(name)」配置无效(\(reason)),已暂时使用 ~/.claude 的默认配置。")
            }
        }
    }
}

/// 连接测试结果。
public enum ProviderTestResult: Equatable, Sendable {
    case ok(milliseconds: Int, reply: String)
    case failed(String)
}

/// 提供商连接测试:发一条极小的 `/v1/messages` 请求。
public enum ProviderTester {
    /// 测试连接与密钥。
    /// - Parameters:
    ///   - provider: 提供商
    ///   - key: 密钥
    ///   - session: URL 会话(测试可注入)
    ///   - timeout: 超时秒数
    /// - Returns: 结果(错误信息不含密钥)
    public static func test(_ provider: ModelProvider, key: String, session: URLSession? = nil, timeout: TimeInterval = 30) async -> ProviderTestResult {
        do { try provider.validate() } catch { return .failed(error.localizedDescription) }
        let hasKey = !key.trimmingCharacters(in: .whitespaces).isEmpty
        if provider.requiresKey, !hasKey { return .failed(String(localized: "未填写 API Key")) }
        guard let base = provider.url else { return .failed(String(localized: "地址无效")) }
        let isOpenAI = provider.isOpenAIProtocol
        var request = URLRequest(url: base.appendingPathComponent(isOpenAI ? "chat/completions" : "v1/messages"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !isOpenAI { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        applyAuth(&request, provider: provider, key: key)
        let body: [String: Any] = ["model": provider.model, "max_tokens": 16, "messages": [["role": "user", "content": "ping"]]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let urlSession = session ?? URLSession(configuration: .ephemeral)
        let started = ContinuousClock.now
        do {
            let (data, response) = try await urlSession.data(for: request)
            let ms = OMLogger.milliseconds(since: started)
            guard let http = response as? HTTPURLResponse else { return .failed(String(localized: "无效的响应")) }
            guard (200..<300).contains(http.statusCode) else { return .failed(describe(status: http.statusCode, body: data)) }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let content: String
            if isOpenAI {
                content = (((object?["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any])?["content"] as? String ?? ""
            } else {
                content = (object?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
            }
            return .ok(milliseconds: ms, reply: String(content.prefix(60)))
        } catch let error as URLError {
            return .failed(String(localized: "无法连接:\(ModelGateway.describe(error))"))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 按协议与鉴权方式设置请求头(密钥为空时不设置鉴权头)。
    /// - Parameters:
    ///   - request: 待设置的请求
    ///   - provider: 提供商
    ///   - key: 密钥
    static func applyAuth(_ request: inout URLRequest, provider: ModelProvider, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            if provider.usesAPIKeyHeader == true, !provider.isOpenAIProtocol {
                request.setValue(trimmed, forHTTPHeaderField: "x-api-key")
            } else {
                request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
            }
        }
        // 兼容头对两种协议都生效(Anthropic 协议的 Zen 端点同样需要 UA 与会话头);测试请求用一次性会话
        if provider.opencodeCompat == true {
            for (name, value) in ProviderBridge.opencodeHeaders() { request.setValue(value, forHTTPHeaderField: name) }
        }
        for line in ModelProvider.headerLines(provider.customHeaders ?? "") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            request.setValue(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces))
        }
    }

    /// 把 HTTP 状态翻译成可操作的提示(正文仅取前 160 字,且经脱敏)。
    static func describe(status: Int, body: Data) -> String {
        let snippet = LogRedactor.redact(String(String(data: body, encoding: .utf8)?.prefix(160) ?? ""))
        if let special = UpstreamHints.message(for: body) { return special }
        let head: String
        switch status {
        case 401, 403: head = String(localized: "鉴权失败(\(status)):请检查 API Key 是否正确、是否有该模型权限")
        case 404: head = String(localized: "接口或模型不存在(404):请确认地址是 Anthropic 兼容端点,模型名正确")
        case 429: head = String(localized: "触发限流或额度不足(429)")
        case 500...: head = String(localized: "上游服务出错(\(status))")
        default: head = String(localized: "请求失败(\(status))")
        }
        return snippet.isEmpty ? head : "\(head):\(snippet)"
    }
}

/// 从提供商的 `/v1/models` 获取模型列表。
public enum ProviderModelFetcher {
    /// 获取模型 ID 列表。
    /// - Parameters:
    ///   - provider: 提供商
    ///   - key: 密钥
    ///   - session: URL 会话(测试可注入)
    ///   - timeout: 超时秒数
    /// - Returns: 成功返回去重后的模型 ID;失败返回不含密钥的错误描述
    public static func fetch(_ provider: ModelProvider, key: String, session: URLSession? = nil, timeout: TimeInterval = 20) async -> Result<[String], ModelFetchError> {
        guard let base = provider.url else { return .failure(ModelFetchError(message: String(localized: "地址无效"))) }
        if provider.requiresKey, key.trimmingCharacters(in: .whitespaces).isEmpty { return .failure(ModelFetchError(message: String(localized: "未填写 API Key"))) }
        var request = URLRequest(url: base.appendingPathComponent(provider.isOpenAIProtocol ? "models" : "v1/models"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if !provider.isOpenAIProtocol { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        ProviderTester.applyAuth(&request, provider: provider, key: key)
        do {
            let (data, response) = try await (session ?? URLSession(configuration: .ephemeral)).data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(ModelFetchError(message: String(localized: "无效的响应"))) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(ModelFetchError(message: ProviderTester.describe(status: http.statusCode, body: data)))
            }
            let ids = parse(data)
            return ids.isEmpty ? .failure(ModelFetchError(message: String(localized: "该端点没有返回模型列表"))) : .success(ids)
        } catch let error as URLError {
            return .failure(ModelFetchError(message: String(localized: "无法连接:\(ModelGateway.describe(error))")))
        } catch {
            return .failure(ModelFetchError(message: error.localizedDescription))
        }
    }

    /// 解析 `{"data":[{"id":"…"}]}`(兼容 `models` 数组与字符串数组)。
    /// - Parameter data: 响应体
    /// - Returns: 去重、保持顺序的模型 ID
    public static func parse(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var raw: [Any] = []
        if let dictionary = object as? [String: Any] {
            raw = (dictionary["data"] as? [Any]) ?? (dictionary["models"] as? [Any]) ?? []
        } else if let array = object as? [Any] {
            raw = array
        }
        var seen = Set<String>()
        var result: [String] = []
        for item in raw {
            let id = (item as? String) ?? (item as? [String: Any])?["id"] as? String
            if let id, !id.isEmpty, seen.insert(id).inserted { result.append(id) }
        }
        return result
    }
}

/// 模型列表获取失败。
public struct ModelFetchError: Error, Equatable, Sendable {
    public var message: String
}

/// 设置页使用的可观察模型:提供商列表、启用项与密钥存取(读写盘均为小文件)。
@MainActor
@Observable
public final class ProviderSettingsModel {
    public private(set) var snapshot = ProviderSnapshot()
    /// 已保存密钥的提供商 ID(缓存,避免界面刷新时反复读盘)
    public private(set) var keyedIds: Set<String> = []
    /// 最近一次错误(展示用)
    public private(set) var lastError: String?
    private let directory: URL

    /// 创建模型。
    /// - Parameter directory: 存储目录(测试可注入)
    public init(directory: URL = ProviderStorage.defaultDirectory) {
        self.directory = directory
        reload()
    }

    /// 重新读取磁盘。
    public func reload() {
        snapshot = ProviderStorage.load(directory: directory)
        keyedIds = ProviderStorage.keyedIds(directory: directory)
    }

    /// 新增或更新提供商。
    /// - Parameter provider: 提供商
    /// - Returns: 校验通过并保存返回 true
    @discardableResult
    public func upsert(_ provider: ModelProvider) -> Bool {
        do {
            var provider = provider
            try provider.validate()
            // 同名自动加序号(排除自己)
            provider.name = ProviderNaming.uniqueName(provider.name, existing: snapshot.providers.filter { $0.id != provider.id }.map(\.name))
            var next = snapshot
            if let index = next.providers.firstIndex(where: { $0.id == provider.id }) { next.providers[index] = provider } else { next.providers.append(provider) }
            try ProviderStorage.save(next, directory: directory)
            snapshot = next
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            Log.agent.error("保存模型提供商失败", error: error)
            return false
        }
    }

    /// 删除提供商及其密钥。
    public func remove(id: String) {
        var next = snapshot
        next.providers.removeAll { $0.id == id }
        next.mapping.removeTargets(of: id)
        persist(next)
        do {
            try ProviderStorage.setKey("", for: id, directory: directory)
            keyedIds.remove(id)
        } catch {
            lastError = error.localizedDescription
            Log.agent.error("删除提供商密钥失败", error: error, ["provider": id])
        }
    }

    /// 启用或停用某个提供商(停用后不能被选为映射目标;已有的映射在会话启动时会给出提示)。
    /// - Parameters:
    ///   - id: 提供商 ID
    ///   - enabled: 是否启用
    public func setEnabled(_ id: String, _ enabled: Bool) {
        var next = snapshot
        guard let index = next.providers.firstIndex(where: { $0.id == id }) else { return }
        next.providers[index].enabled = enabled ? nil : false
        persist(next)
    }

    /// 为新建的提供商生成唯一 ID 与名称。
    /// - Parameter provider: 草稿(ID 与名称可能冲突)
    /// - Returns: 调整后的副本
    public func makeUnique(_ provider: ModelProvider) -> ModelProvider {
        var copy = provider
        if snapshot.providers.contains(where: { $0.id == copy.id }) { copy.id = "\(copy.id)-\(UUID().uuidString.prefix(4).lowercased())" }
        copy.name = ProviderNaming.uniqueName(copy.name, existing: snapshot.providers.map(\.name))
        return copy
    }

    /// 设置某个槽位的映射目标(nil 清除;清除默认槽位即整体回到系统默认)。新建会话与重连后生效,空闲的会话会即时刷新。
    /// - Parameters:
    ///   - slot: 槽位
    ///   - target: 目标
    public func setMapping(_ slot: ModelSlot, _ target: ModelTarget?) {
        var next = snapshot
        next.mapping[slot] = target
        persist(next)
        NotificationCenter.default.post(name: .omModelMappingChanged, object: nil)
    }

    /// 启用或停用映射(停用后保留映射内容,Claude Code 走 ~/.claude 与官方登录)。空闲会话会即时刷新。
    /// - Parameter enabled: 是否启用
    public func setUseMapping(_ enabled: Bool) {
        var next = snapshot
        next.useMapping = enabled
        persist(next)
        NotificationCenter.default.post(name: .omModelMappingChanged, object: nil)
    }

    /// 是否已保存密钥(含 `OMA_PROVIDER_KEY` 环境变量)。
    public func hasKey(id: String) -> Bool { keyedIds.contains(id) || ProviderStorage.hasEnvironmentKey }

    /// 读取密钥(仅用于「测试连接」)。
    public func key(id: String) -> String? { ProviderStorage.key(for: id, directory: directory) }

    /// 保存密钥(空串删除)。
    public func setKey(_ key: String, id: String) {
        do {
            try ProviderStorage.setKey(key, for: id, directory: directory)
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { keyedIds.remove(id) } else { keyedIds.insert(id) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.agent.error("保存密钥失败", error: error)
        }
    }

    private func persist(_ next: ProviderSnapshot) {
        do {
            try ProviderStorage.save(next, directory: directory)
            snapshot = next
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.agent.error("保存模型提供商失败", error: error)
        }
    }
}

extension Notification.Name {
    /// 模型映射发生变化(设置页写入后发出,空闲会话据此刷新)。
    public static let omModelMappingChanged = Notification.Name("com.ixxxxoooo.OhMyAgent.modelMappingChanged")
}
