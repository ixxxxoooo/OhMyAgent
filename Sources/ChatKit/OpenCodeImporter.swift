// @author ixxxxoooo
// 从本机 OpenCode 的配置导入提供商(仅在用户点击并确认后)。
//
// 读取:`~/.config/opencode/opencode.json`(厂商、baseURL、模型)与 `auth.json`(各厂商的密钥)。
// 两阶段:`scan` 只列出厂商摘要(不读取、不返回任何密钥);用户确认后 `load` 才读取密钥。
// 密钥永不写日志、不出现在 `description` 里。

import Foundation
import OMLog

/// OpenCode 导入器。
public enum OpenCodeImporter {
    /// 可导入的一项。
    public struct Candidate: Identifiable, Sendable {
        public var id: String { provider.id }
        public var provider: ModelProvider
        /// 是否能找到密钥(不暴露密钥本身)
        public var hasKey: Bool
        /// 密钥(仅 `load` 阶段填充;不可记录)
        fileprivate(set) var key: String?
    }

    /// 默认配置目录。
    public static var defaultHome: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/opencode", isDirectory: true) }

    /// 已知厂商 ID → 预设 ID。
    static let knownPresets: [String: String] = [
        "opencode": "opencode-free", "opencode-go": "opencode-go", "anthropic": "anthropic", "openai": "openai",
        "deepseek": "deepseek", "openrouter": "openrouter", "google": "gemini", "ollama": "ollama", "lmstudio": "lmstudio",
    ]

    /// 扫描可导入的厂商(不含密钥)。
    /// - Parameter home: OpenCode 配置目录(测试可注入)
    /// - Returns: 候选列表
    public static func scan(home: URL = defaultHome) -> [Candidate] {
        build(home: home, includeKeys: false)
    }

    /// 读取候选及其密钥(应仅在用户确认后调用)。
    /// - Parameter home: OpenCode 配置目录
    /// - Returns: 带密钥的候选列表
    public static func load(home: URL = defaultHome) -> [Candidate] {
        build(home: home, includeKeys: true)
    }

    private static func json(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    private static func build(home: URL, includeKeys: Bool) -> [Candidate] {
        let config = json(home.appendingPathComponent("opencode.json"))
        // auth.json 可能在配置目录或 ~/.local/share/opencode 下
        var auth = json(home.appendingPathComponent("auth.json"))
        if auth.isEmpty { auth = json(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/opencode/auth.json")) }
        let providers = (config["provider"] as? [String: Any]) ?? [:]
        var ids = Set(providers.keys)
        ids.formUnion(auth.keys)
        var result: [Candidate] = []
        for id in ids.sorted() {
            let entry = providers[id] as? [String: Any] ?? [:]
            let options = entry["options"] as? [String: Any] ?? [:]
            let authKey = (auth[id] as? [String: Any]).flatMap { ($0["key"] as? String) ?? ($0["apiKey"] as? String) }
            let configKey = options["apiKey"] as? String
            let secret = [authKey, configKey].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("{env:") }
            guard var provider = makeProvider(id: id, entry: entry, options: options) else { continue }
            if let models = entry["models"] as? [String: Any], !models.isEmpty {
                let list = models.keys.sorted().map { key in
                    ProviderModel(id: key, displayName: (models[key] as? [String: Any])?["name"] as? String)
                }
                provider.models = list
                if !list.contains(where: { $0.id == provider.model }), let first = list.first { provider.model = first.id }
            }
            var candidate = Candidate(provider: provider, hasKey: secret != nil, key: nil)
            if includeKeys { candidate.key = secret }
            result.append(candidate)
        }
        return result
    }

    /// 由 OpenCode 条目生成提供商:自定义条目用其 baseURL,已知厂商用预设。
    private static func makeProvider(id: String, entry: [String: Any], options: [String: Any]) -> ModelProvider? {
        let name = (entry["name"] as? String) ?? id
        if let base = options["baseURL"] as? String, !base.isEmpty {
            let npm = (entry["npm"] as? String) ?? ""
            let isAnthropic = npm.contains("anthropic")
            var url = base
            while url.hasSuffix("/") { url.removeLast() }
            if isAnthropic, url.hasSuffix("/v1") { url.removeLast(3) }
            let models = (entry["models"] as? [String: Any])?.keys.sorted() ?? []
            return ModelProvider(id: "opencode-\(id)", name: name, baseURL: url, model: models.first ?? "", protocolKind: isAnthropic ? nil : .openai,
                                 opencodeCompat: id.hasPrefix("opencode") ? true : nil)
        }
        guard let presetId = knownPresets[id], let preset = ProviderPreset.all.first(where: { $0.id == presetId }) else { return nil }
        var provider = preset.makeProvider()
        provider.id = "opencode-\(id)"
        provider.name = (entry["name"] as? String) ?? preset.name
        return provider
    }

    /// 把候选写入设置(含密钥)。
    /// - Parameters:
    ///   - candidates: `load` 返回的候选
    ///   - model: 设置模型
    /// - Returns: 实际导入的数量
    @MainActor
    @discardableResult
    public static func importAll(_ candidates: [Candidate], into model: ProviderSettingsModel) -> Int {
        var count = 0
        for candidate in candidates {
            let provider = model.makeUnique(candidate.provider)
            guard model.upsert(provider) else { continue }
            if let key = candidate.key { model.setKey(key, id: provider.id) }
            count += 1
        }
        Log.agent.info("已从 OpenCode 导入提供商", ["count": "\(count)"])
        return count
    }
}
