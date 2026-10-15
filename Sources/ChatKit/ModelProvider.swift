// @author ygw
// 模型提供商:每个会话启动时,经 ACP 的 `_meta.claudeCode.options` 把「上游地址 + 模型 + 密钥」
// 交给 Claude Code,不改动用户的 `~/.claude/settings.json`(做法参考 baocode 的 launchEnvironment)。
//
// 要点:
// - 非密钥部分(地址、模型、清空用户自己的 Bedrock/网关变量)放进 `settings.env`(程序化设置层,
//   优先于用户/项目设置);
// - 密钥(ANTHROPIC_AUTH_TOKEN)只放进进程 `env`:适配器会把 `--settings` 打到 stderr/命令行,
//   密钥放那里会泄露;
// - 仅支持 Anthropic 协议直连(DeepSeek/GLM/Kimi/MiniMax/Qwen 等官方 Anthropic 兼容端点)。

import ACPKit
import Foundation
import OMLog

/// 模型提供商配置(不含密钥)。
public struct ModelProvider: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Anthropic 协议端点(如 `https://api.deepseek.com/anthropic`)
    public var baseURL: String
    /// 主模型
    public var model: String
    /// 各角色模型(留空则都用主模型)
    public var opusModel: String?
    public var sonnetModel: String?
    public var haikuModel: String?
    /// 来源预设(仅用于界面展示)
    public var presetId: String?

    public init(id: String, name: String, baseURL: String, model: String, opusModel: String? = nil, sonnetModel: String? = nil, haikuModel: String? = nil, presetId: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.opusModel = opusModel
        self.sonnetModel = sonnetModel
        self.haikuModel = haikuModel
        self.presetId = presetId
    }

    /// 配置校验错误。
    public enum ValidationError: Error, LocalizedError, Equatable {
        case emptyName, invalidBaseURL, emptyModel
        public var errorDescription: String? {
            switch self {
            case .emptyName: "名称不能为空"
            case .invalidBaseURL: "地址必须是 http(s) 绝对地址"
            case .emptyModel: "模型不能为空"
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

/// 常用提供商预设(均为官方 Anthropic 兼容端点;参考 kuku 预设)。
public struct ProviderPreset: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var models: [String]
    public var hint: String

    /// 默认模型(列表第一个)。
    public var defaultModel: String { models.first ?? "" }

    /// 预设列表。
    public static let all: [ProviderPreset] = [
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/anthropic", models: ["deepseek-chat", "deepseek-reasoner"], hint: "官方原生兼容 Anthropic 协议,国内直连。注意 `/v1` 是 OpenAI 协议端点,这里必须用 `/anthropic`。"),
        ProviderPreset(id: "glm", name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/anthropic", models: ["glm-4.6", "glm-4.5", "glm-4.5-air"], hint: "智谱开放平台 Claude API 兼容端点"),
        ProviderPreset(id: "kimi", name: "Kimi(Moonshot)", baseURL: "https://api.moonshot.cn/anthropic", models: ["kimi-k2-turbo-preview", "kimi-k2-0905-preview"], hint: "海外可改用 api.moonshot.ai/anthropic"),
        ProviderPreset(id: "minimax", name: "MiniMax", baseURL: "https://api.minimaxi.com/anthropic", models: ["MiniMax-M2"], hint: "海外可改用 api.minimax.io/anthropic"),
        ProviderPreset(id: "qwen", name: "阿里云百炼(Qwen)", baseURL: "https://dashscope.aliyuncs.com/apps/anthropic", models: ["qwen3-coder-plus", "qwen3-coder-flash"], hint: "Coding Plan 用户端点略有不同,可手动修改"),
    ]

    /// 由预设生成提供商。
    public func makeProvider() -> ModelProvider {
        ModelProvider(id: id, name: name, baseURL: baseURL, model: defaultModel, presetId: id)
    }
}

/// 生成 Claude Code 的会话级模型环境。
public enum ProviderLaunch {
    /// 提供商会话必须清空的用户侧变量(其他后端、网关、旧模型名)。
    public static let clearedVariables = [
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_CUSTOM_HEADERS",
        "ANTHROPIC_API_BASE_URL", "CLAUDE_AGENT_API_BASE_URL",
        "ANTHROPIC_CUSTOM_MODEL_OPTION", "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME", "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION",
        "ANTHROPIC_DEFAULT_FABLE_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
    ]

    /// 非密钥环境(放进 `settings.env`)。
    /// - Parameter provider: 提供商
    /// - Returns: 环境字典
    public static func publicEnvironment(_ provider: ModelProvider) -> [String: String] {
        var env: [String: String] = [:]
        for name in clearedVariables { env[name] = "" }
        env["ANTHROPIC_BASE_URL"] = provider.normalizedBaseURL
        env["ANTHROPIC_API_KEY"] = ""
        env["ANTHROPIC_MODEL"] = provider.model
        env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = nonEmpty(provider.opusModel) ?? provider.model
        env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = nonEmpty(provider.sonnetModel) ?? provider.model
        env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = nonEmpty(provider.haikuModel) ?? provider.model
        return env
    }

    /// 生成 `session/new|load|resume|fork` 的 `_meta`。
    /// - Parameters:
    ///   - provider: 提供商
    ///   - key: API 密钥(只进进程 env)
    /// - Returns: `_meta` JSON
    public static func sessionMeta(_ provider: ModelProvider, key: String) -> JSONValue {
        let publicEnv = publicEnvironment(provider).mapValues(JSONValue.string)
        let settings: JSONValue = .object(["model": .string(provider.model), "apiKeyHelper": .string(""), "env": .object(publicEnv)])
        let secretEnv: JSONValue = .object(["ANTHROPIC_AUTH_TOKEN": .string(key)])
        return .object(["claudeCode": .object(["options": .object(["settings": settings, "env": secretEnv])])])
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
}

/// 已解析、可直接用于启动会话的提供商。
public struct ResolvedProvider: Sendable {
    public var provider: ModelProvider
    /// 会话 `_meta`(含密钥,不可记录)
    public var meta: JSONValue
}

/// 提供商文件快照(磁盘格式)。
public struct ProviderSnapshot: Codable, Sendable, Equatable {
    public var active: String?
    public var providers: [ModelProvider]
    public init(active: String? = nil, providers: [ModelProvider] = []) {
        self.active = active
        self.providers = providers
    }
}

/// 提供商与密钥的磁盘存取(纯函数式,可在后台线程调用)。
public enum ProviderStorage {
    /// 默认目录:`~/Library/Application Support/OhMyAgent`。
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OhMyAgent", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/OhMyAgent")
    }

    static func providersURL(_ directory: URL) -> URL { directory.appendingPathComponent("providers.json") }
    static func keysURL(_ directory: URL) -> URL { directory.appendingPathComponent("provider-keys.json") }

    /// 读取提供商配置(缺失或损坏返回空)。
    public static func load(directory: URL = defaultDirectory) -> ProviderSnapshot {
        guard let data = try? Data(contentsOf: providersURL(directory)) else { return ProviderSnapshot() }
        do {
            return try JSONDecoder().decode(ProviderSnapshot.self, from: data)
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

    /// 读取密钥:环境变量 `OMA_PROVIDER_KEY` 优先(调试用),其次密钥文件。
    public static func key(for id: String, directory: URL = defaultDirectory, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let value = environment["OMA_PROVIDER_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        guard let data = try? Data(contentsOf: keysURL(directory)),
              let map = try? JSONDecoder().decode([String: String].self, from: data),
              let value = map[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// 写入或删除密钥(权限 0600)。
    /// - Parameters:
    ///   - key: 密钥,空串表示删除
    ///   - id: 提供商 ID
    /// - Throws: 写盘错误
    public static func setKey(_ key: String, for id: String, directory: URL = defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = keysURL(directory)
        var map = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { map.removeValue(forKey: id) } else { map[id] = trimmed }
        try JSONEncoder().encode(map).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 解析当前启用的提供商。
    /// - Returns: 配置齐全返回 `ResolvedProvider`;未启用返回 nil;缺密钥时抛 `missingKey`
    /// - Throws: `ResolveError`
    public static func resolveActive(directory: URL = defaultDirectory, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ResolvedProvider? {
        let snapshot = load(directory: directory)
        guard let activeId = snapshot.active, let provider = snapshot.providers.first(where: { $0.id == activeId }) else { return nil }
        do { try provider.validate() } catch { throw ResolveError.invalid(provider.name, error.localizedDescription) }
        guard let key = key(for: provider.id, directory: directory, environment: environment) else { throw ResolveError.missingKey(provider.name) }
        return ResolvedProvider(provider: provider, meta: ProviderLaunch.sessionMeta(provider, key: key))
    }

    /// 解析错误(会话会据此提示并回退到系统默认)。
    public enum ResolveError: Error, LocalizedError, Equatable {
        case missingKey(String)
        case invalid(String, String)
        public var errorDescription: String? {
            switch self {
            case .missingKey(let name): "模型提供商「\(name)」未设置 API Key:请在 设置 → 模型提供商 中填写。已暂时使用 ~/.claude 的默认配置。"
            case .invalid(let name, let reason): "模型提供商「\(name)」配置无效(\(reason)),已暂时使用 ~/.claude 的默认配置。"
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
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return .failed("未填写 API Key") }
        guard let base = provider.url else { return .failed("地址无效") }
        var request = URLRequest(url: base.appendingPathComponent("v1/messages"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": provider.model, "max_tokens": 16, "messages": [["role": "user", "content": "ping"]]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let urlSession = session ?? URLSession(configuration: .ephemeral)
        let started = ContinuousClock.now
        do {
            let (data, response) = try await urlSession.data(for: request)
            let ms = OMLogger.milliseconds(since: started)
            guard let http = response as? HTTPURLResponse else { return .failed("无效的响应") }
            guard (200..<300).contains(http.statusCode) else { return .failed(describe(status: http.statusCode, body: data)) }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let content = (object?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
            return .ok(milliseconds: ms, reply: String(content.prefix(60)))
        } catch let error as URLError {
            return .failed("无法连接:\(ModelGateway.describe(error))")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 把 HTTP 状态翻译成可操作的提示(正文仅取前 160 字,且经脱敏)。
    static func describe(status: Int, body: Data) -> String {
        let snippet = LogRedactor.redact(String(String(data: body, encoding: .utf8)?.prefix(160) ?? ""))
        let head: String
        switch status {
        case 401, 403: head = "鉴权失败(\(status)):请检查 API Key 是否正确、是否有该模型权限"
        case 404: head = "接口或模型不存在(404):请确认地址是 Anthropic 兼容端点,模型名正确"
        case 429: head = "触发限流或额度不足(429)"
        case 500...: head = "上游服务出错(\(status))"
        default: head = "请求失败(\(status))"
        }
        return snippet.isEmpty ? head : "\(head):\(snippet)"
    }
}

/// 设置页使用的可观察模型:提供商列表、启用项与密钥存取(读写盘均为小文件)。
@MainActor
@Observable
public final class ProviderSettingsModel {
    public private(set) var snapshot = ProviderSnapshot()
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
    public func reload() { snapshot = ProviderStorage.load(directory: directory) }

    /// 新增或更新提供商。
    /// - Parameter provider: 提供商
    /// - Returns: 校验通过并保存返回 true
    @discardableResult
    public func upsert(_ provider: ModelProvider) -> Bool {
        do {
            try provider.validate()
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
        if next.active == id { next.active = nil }
        persist(next)
        try? ProviderStorage.setKey("", for: id, directory: directory)
    }

    /// 设置启用项(nil 表示沿用 ~/.claude 默认配置)。新建会话与重连后生效。
    public func setActive(_ id: String?) {
        var next = snapshot
        next.active = id
        persist(next)
    }

    /// 是否已保存密钥(含 `OMA_PROVIDER_KEY` 环境变量)。
    public func hasKey(id: String) -> Bool { ProviderStorage.key(for: id, directory: directory) != nil }

    /// 读取密钥(仅用于「测试连接」)。
    public func key(id: String) -> String? { ProviderStorage.key(for: id, directory: directory) }

    /// 保存密钥(空串删除)。
    public func setKey(_ key: String, id: String) {
        do {
            try ProviderStorage.setKey(key, for: id, directory: directory)
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
