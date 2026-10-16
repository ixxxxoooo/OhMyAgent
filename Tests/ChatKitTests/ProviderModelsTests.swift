// @author ixxxxoooo
// 多厂商模型:协议、模型清单迁移与合并、命名去重、输入框菜单、协议代理桥接、OpenCode 导入。

import ACPKit
import Foundation
import ProviderProxyKit
import Testing
@testable import ChatKit

private func tempDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-models-\(UUID().uuidString)", isDirectory: true)
}

@Suite("提供商模型清单")
struct ProviderModelListTests {
    @Test("旧 availableModels 迁移为 models,重命名与启用状态在合并时保留")
    func migrateAndMerge() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"providers":[{"id":"p","name":"P","baseURL":"https://x.com","model":"a","availableModels":["b","c"]}]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("providers.json"))
        var provider = try #require(ProviderStorage.load(directory: dir).providers.first)
        #expect(provider.models?.map(\.id) == ["a", "b", "c"])
        #expect(provider.availableModels == nil)
        provider.models?[1].displayName = "乙"
        provider.models?[2].enabled = false
        provider.mergeModels(["b", "d"])
        #expect(provider.models?.map(\.id) == ["a", "b", "c", "d"])
        #expect(provider.displayName(forModel: "b") == "乙")
        #expect(provider.menuModels.map(\.id) == ["a", "b", "d"], "停用的模型不出现在菜单")
    }

    @Test("同名自动加序号")
    func unique() {
        #expect(ProviderNaming.uniqueName("自定义", existing: []) == "自定义")
        #expect(ProviderNaming.uniqueName("自定义", existing: ["自定义"]) == "自定义 2")
        #expect(ProviderNaming.uniqueName("自定义", existing: ["自定义", "自定义 2", "自定义 3"]) == "自定义 4")
        #expect(ProviderNaming.uniqueName("  ", existing: []) == "Provider")
    }

    @Test("模型级上下文窗口优先于提供商级")
    func contextWindow() {
        var provider = ModelProvider(id: "p", name: "P", baseURL: "https://x.com", model: "a", contextWindow: 100)
        #expect(provider.effectiveContextWindow == 100)
        provider.models = [ProviderModel(id: "a", contextWindow: 500)]
        #expect(provider.effectiveContextWindow == 500)
        let gateway = URL(string: "http://127.0.0.1:9/t")!
        #expect(ProviderLaunch.publicEnvironment(ModelProviderTests.mapping(provider, "a"), gateway: gateway)["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] == "500")
    }

    @Test("旧文件无新字段:协议默认 Anthropic、默认启用;protocol 键往返")
    func codable() throws {
        let old = try JSONDecoder().decode(ModelProvider.self, from: Data(#"{"id":"p","name":"P","baseURL":"https://x.com","model":"m"}"#.utf8))
        #expect(old.protocolKind == nil && !old.isOpenAIProtocol && old.isEnabled && old.requiresKey)
        let preset = try #require(ProviderPreset.all.first { $0.id == "openai" })
        let data = try JSONEncoder().encode(preset.makeProvider())
        #expect(String(decoding: data, as: UTF8.self).contains(#""protocol":"openai""#))
        #expect(try JSONDecoder().decode(ModelProvider.self, from: data).isOpenAIProtocol)
    }

    @Test("预设:覆盖 OpenAI 协议厂商、本地模型与 OpenCode,且全部通过校验")
    func presets() throws {
        for id in ["openai", "openrouter", "gemini", "ollama", "lmstudio", "opencode-go", "opencode-free", "opencode"] {
            #expect(ProviderPreset.all.contains { $0.id == id }, "缺少预设 \(id)")
        }
        let free = try #require(ProviderPreset.all.first { $0.id == "opencode-free" }).makeProvider()
        #expect(free.isOpenAIProtocol && free.opencodeCompat == true && free.baseURL == "https://opencode.ai/zen/go/v1")
        for item in ProviderPreset.all { #expect(throws: Never.self) { try item.makeProvider().validate() } }
    }
}

@Suite("输入框模型菜单")
struct ProviderMenuBuilderTests {
    private func snapshot() -> ProviderSnapshot {
        var a = ModelProvider(id: "a", name: "Alpha", baseURL: "https://a.com", model: "a1", models: [ProviderModel(id: "a1"), ProviderModel(id: "a2", displayName: "阿尔法二")])
        var b = ModelProvider(id: "b", name: "Beta", baseURL: "https://b.com", model: "b1")
        b.enabled = false
        let c = ModelProvider(id: "c", name: "本地", baseURL: "http://localhost:1/v1", model: "m", protocolKind: .openai, keyOptional: true)
        let d = ModelProvider(id: "d", name: "Delta", baseURL: "https://d.com", model: "d1")
        a.models?[0].displayName = "A 一"
        return ProviderSnapshot(providers: [a, b, c, d])
    }

    @Test("只含已启用且已配置密钥(或无需密钥)的提供商")
    func filtering() {
        let sections = ProviderMenuBuilder.sections(snapshot: snapshot(), hasKey: { $0 == "a" || $0 == "b" })
        #expect(sections.map(\.providerId) == ["a", "c"])
    }

    @Test("搜索匹配厂商名或模型展示名/ID,厂商名命中保留全部模型")
    func search() {
        let all = snapshot()
        let byModel = ProviderMenuBuilder.sections(snapshot: all, hasKey: { _ in true }, query: "阿尔法")
        #expect(byModel.count == 1 && byModel[0].models.map(\.id) == ["a2"])
        let byVendor = ProviderMenuBuilder.sections(snapshot: all, hasKey: { _ in true }, query: "alpha")
        #expect(byVendor.first?.models.count == 2)
        #expect(ProviderMenuBuilder.sections(snapshot: all, hasKey: { _ in true }, query: "不存在").isEmpty)
    }
}

@Suite("协议代理桥接")
struct ProviderBridgeTests {
    private let provider = ModelProvider(id: "oa", name: "OA", baseURL: "https://api.example.com/v1", model: "gpt", protocolKind: .openai, opencodeCompat: true)

    @Test("meta 指向本机网关,真实密钥与上游地址都不进入 meta")
    func activate() async throws {
        let proxy = ProviderProxy()
        let resolved = ModelProviderTests.mapping(provider, "gpt", key: "sk-real-secret")
        let active = try await ProviderBridge.activate(resolved, sessionKey: "t1", proxy: proxy)
        let text = String(describing: active.meta)
        #expect(!text.contains("sk-real-secret"))
        #expect(text.contains("127.0.0.1"))
        #expect(text.contains(ProviderLaunch.placeholderToken))
        #expect(!text.contains("api.example.com"))
        #expect(active.infos[.main]?.providerName == "OA" && active.mainModel == "gpt")
        await proxy.shutdown()
    }

    @Test("Anthropic 协议同样经网关(透传),meta 不含上游地址")
    func passthrough() async throws {
        let direct = ModelProvider(id: "d", name: "D", baseURL: "https://x.com/anthropic", model: "m")
        let proxy = ProviderProxy()
        let active = try await ProviderBridge.activate(ModelProviderTests.mapping(direct, "m"), sessionKey: "t2", proxy: proxy)
        #expect(!String(describing: active.meta).contains("x.com"))
        await ProviderBridge.deactivate(sessionKey: "t2", proxy: proxy)
        await proxy.shutdown()
    }

    @Test("路由携带 OpenCode 兼容头与自定义头")
    func routeHeaders() throws {
        var custom = provider
        custom.customHeaders = "X-Org: abc"
        let route = try #require(ProviderBridge.route(for: custom, key: "k"))
        #expect(route.extraHeaders["x-opencode-session"]?.hasPrefix("ses_") == true)
        #expect(route.extraHeaders["X-Org"] == "abc")
        #expect(route.apiKey == "k")
    }

    @Test("停用的提供商不能作默认槽位;无需密钥的提供商缺密钥也能解析")
    func resolveRules() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var off = ModelProvider(id: "off", name: "Off", baseURL: "https://x.com", model: "m")
        off.enabled = false
        let local = ModelProvider(id: "local", name: "Local", baseURL: "http://localhost:11434/v1", model: "m", protocolKind: .openai, keyOptional: true)
        try ProviderStorage.save(ProviderSnapshot(mapping: ModelMapping(slots: [.main: ModelTarget(providerId: "off", model: "m")]), providers: [off, local]), directory: dir)
        #expect(throws: ProviderStorage.ResolveError.disabled("Off")) { try ProviderStorage.resolveMapping(directory: dir, environment: [:]) }
        try ProviderStorage.save(ProviderSnapshot(mapping: ModelMapping(slots: [.main: ModelTarget(providerId: "local", model: "m")]), providers: [off, local]), directory: dir)
        let resolved = try #require(try ProviderStorage.resolveMapping(directory: dir, environment: [:]))
        #expect(resolved.main.provider.id == "local")
    }
}

@Suite("OpenCode 导入")
struct OpenCodeImporterTests {
    private func makeHome() throws -> URL {
        let home = tempDirectory()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = #"{"provider":{"deepseek":{"npm":"@ai-sdk/openai-compatible","name":"DeepSeek","options":{"baseURL":"https://api.deepseek.com/v1/","apiKey":"sk-config-key"},"models":{"deepseek-chat":{"name":"DeepSeek Chat"},"deepseek-reasoner":{}}},"ant":{"npm":"@ai-sdk/anthropic","options":{"baseURL":"https://api.example.com/v1"},"models":{"c1":{}}}}}"#
        let auth = #"{"opencode":{"type":"api","key":"sk-auth-key"},"opencode-go":{"type":"api","key":"sk-go-key"}}"#
        try Data(config.utf8).write(to: home.appendingPathComponent("opencode.json"))
        try Data(auth.utf8).write(to: home.appendingPathComponent("auth.json"))
        return home
    }

    @Test("scan 只给摘要,不含任何密钥")
    func scanHasNoKeys() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let found = OpenCodeImporter.scan(home: home)
        #expect(found.allSatisfy { $0.key == nil })
        #expect(!String(describing: found).contains("sk-"))
        let deepseek = try #require(found.first { $0.provider.id == "opencode-deepseek" })
        #expect(deepseek.hasKey && deepseek.provider.isOpenAIProtocol)
        #expect(deepseek.provider.baseURL == "https://api.deepseek.com/v1")
        #expect(deepseek.provider.models?.first?.name == "DeepSeek Chat")
        let anthropic = try #require(found.first { $0.provider.id == "opencode-ant" })
        #expect(!anthropic.provider.isOpenAIProtocol && anthropic.provider.baseURL == "https://api.example.com", "Anthropic 协议去掉 /v1")
        #expect(!anthropic.hasKey)
        #expect(found.contains { $0.provider.id == "opencode-opencode-go" && $0.hasKey })
    }

    @MainActor
    @Test("确认后导入:写入提供商与密钥,同名自动加序号")
    func importKeys() throws {
        let home = try makeHome()
        let store = tempDirectory()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: store) }
        let model = ProviderSettingsModel(directory: store)
        model.upsert(ModelProvider(id: "mine", name: "DeepSeek", baseURL: "https://x.com", model: "m"))
        let count = OpenCodeImporter.importAll(OpenCodeImporter.load(home: home), into: model)
        #expect(count >= 3)
        #expect(model.snapshot.providers.first { $0.id == "opencode-deepseek" }?.name == "DeepSeek 2")
        #expect(model.key(id: "opencode-deepseek") == "sk-auth-key" || model.key(id: "opencode-deepseek") == "sk-config-key")
        #expect(model.hasKey(id: "opencode-opencode-go"))
    }
}

extension ProviderTesterTests {
    @Test("OpenAI 协议:测试连接走 /chat/completions,取 choices 内容;无需密钥时不带 Authorization")
    func openAITester() async {
        let captured = LockedBox<URLRequest?>(nil)
        StubURLProtocol.handler = { request in
            captured.value = request
            return (200, Data(#"{"choices":[{"message":{"content":"pong"}}]}"#.utf8))
        }
        let provider = ModelProvider(id: "l", name: "L", baseURL: "http://localhost:11434/v1", model: "m", protocolKind: .openai, keyOptional: true)
        let result = await ProviderTester.test(provider, key: "", session: Self.session())
        guard case .ok(_, let reply) = result else { Issue.record("应成功:\(result)"); return }
        #expect(reply == "pong")
        #expect(captured.value?.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(captured.value?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("OpenAI 协议:获取模型列表走 /models 并带 Bearer")
    func openAIFetch() async {
        let captured = LockedBox<URLRequest?>(nil)
        StubURLProtocol.handler = { request in
            captured.value = request
            return (200, Data(#"{"data":[{"id":"m1"}]}"#.utf8))
        }
        let provider = ModelProvider(id: "o", name: "O", baseURL: "https://api.openai.com/v1", model: "m", protocolKind: .openai)
        let result = await ProviderModelFetcher.fetch(provider, key: "sk", session: Self.session())
        #expect((try? result.get()) == ["m1"])
        #expect(captured.value?.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(captured.value?.value(forHTTPHeaderField: "Authorization") == "Bearer sk")
    }

    @Test("x-api-key 鉴权的提供商,测试连接也使用 x-api-key;FreeTierError 给出明确提示")
    func authHeaderAndFreeTier() async {
        let captured = LockedBox<URLRequest?>(nil)
        StubURLProtocol.handler = { request in
            captured.value = request
            return (200, Data(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8))
        }
        var provider = ModelProvider(id: "a", name: "A", baseURL: "https://api.anthropic.com", model: "m")
        provider.usesAPIKeyHeader = true
        _ = await ProviderTester.test(provider, key: "sk-a", session: Self.session())
        #expect(captured.value?.value(forHTTPHeaderField: "x-api-key") == "sk-a")
        #expect(captured.value?.value(forHTTPHeaderField: "Authorization") == nil)
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":{"type":"FreeTierError"}}"#.utf8)) }
        let free = ModelProvider(id: "f", name: "F", baseURL: "https://opencode.ai/zen/v1", model: "m", protocolKind: .openai, keyOptional: true, opencodeCompat: true)
        if case .failed(let message) = await ProviderTester.test(free, key: "", session: Self.session()) {
            #expect(message.contains("OpenCode"))
        } else { Issue.record("应失败") }
    }
}

@MainActor
@Suite("提供商设置模型")
struct ProviderSettingsModelTests {
    @Test("同名保存自动加序号;删除提供商清除映射;密钥缓存随增删更新")
    func settingsModel() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = ProviderSettingsModel(directory: dir)
        #expect(model.upsert(ModelProvider(id: "a", name: "自定义", baseURL: "https://a.com", model: "m")))
        #expect(model.upsert(ModelProvider(id: "b", name: "自定义", baseURL: "https://b.com", model: "m")))
        #expect(model.snapshot.providers.map(\.name) == ["自定义", "自定义 2"])
        // 重复保存同一个不应再被改名
        #expect(model.upsert(model.snapshot.providers[1]))
        #expect(model.snapshot.providers.map(\.name) == ["自定义", "自定义 2"])
        let clone = model.makeUnique(ModelProvider(id: "a", name: "自定义", baseURL: "https://c.com", model: "m"))
        #expect(clone.id != "a" && clone.name == "自定义 3")

        model.setKey("sk-1", id: "a")
        #expect(model.hasKey(id: "a") && model.keyedIds == ["a"])
        model.setMapping(.main, ModelTarget(providerId: "a", model: "m"))
        model.setMapping(.haiku, ModelTarget(providerId: "b", model: "m"))
        model.setEnabled("a", false)
        #expect(model.snapshot.providers.first { $0.id == "a" }?.isEnabled == false)
        model.setEnabled("a", true)
        #expect(model.snapshot.providers.first { $0.id == "a" }?.enabled == nil, "启用状态不落盘,保持文件干净")
        model.setKey("", id: "a")
        #expect(!model.hasKey(id: "a"))
        #expect(ProviderStorage.keyedIds(directory: dir).isEmpty)
        model.remove(id: "a")
        #expect(model.snapshot.mapping[.main] == nil && model.snapshot.mapping[.haiku] != nil)
    }
}

@Suite("模式色调")
struct ModeToneTests {
    @Test("Claude Code 的全部模式都有各自不同的色调,默认模式用强调色而不是灰色")
    func allModes() {
        let tones = ["default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"].map { ModeTone.tone(forMode: $0) }
        #expect(Set(tones).count == tones.count, "每种模式的色调互不相同")
        #expect(ModeTone.tone(forMode: "default") == .accent)
        #expect(ModeTone.tone(forMode: "bypassPermissions") == .red)
    }

    @Test("OpenCode 的 build / plan 有色;未知模式稳定映射到彩色(非灰、非红),同一 ID 恒同色")
    func openCodeAndUnknown() {
        #expect(ModeTone.tone(forMode: "build") == .accent)
        #expect(ModeTone.tone(forMode: "plan") == .blue)
        for id in ["不存在", "custom-agent", "reviewer", "x"] {
            let tone = ModeTone.tone(forMode: id)
            #expect(tone != .neutral && tone != .red)
            #expect(tone == ModeTone.tone(forMode: id))
        }
        #expect(ModeTone.tone(forMode: "") == .accent)
    }
}
