// @author ixxxxoooo
// 模型提供商进阶参数:环境变量映射、鉴权头、会话级覆盖、模型列表解析与预设。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@Suite("提供商进阶参数")
struct ProviderAdvancedTests {
    private func base() -> ModelProvider {
        ModelProvider(id: "p", name: "P", baseURL: "https://x.com/anthropic", model: "m1")
    }

    @Test("高级参数映射为环境变量")
    func advancedEnv() throws {
        let gateway = try #require(URL(string: "http://127.0.0.1:9/t"))
        var provider = base()
        provider.maxOutputTokens = 8192
        provider.contextWindow = 200_000
        provider.effort = "high"
        let env = ProviderLaunch.publicEnvironment(ModelProviderTests.mapping(provider, "m1"), gateway: gateway)
        #expect(env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == "8192")
        #expect(env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] == "200000")
        #expect(env["CLAUDE_CODE_EFFORT_LEVEL"] == "high")
        #expect(ProviderLaunch.publicEnvironment(ModelProviderTests.mapping(base(), "m1"), gateway: gateway)["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == nil)
    }

    @Test("鉴权与自定义头进入网关路由,而不是 Claude 进程")
    func routeCarriesAuth() throws {
        var provider = base()
        provider.usesAPIKeyHeader = true
        provider.customHeaders = "X-Org: abc\n\n X-Token : t "
        let route = try #require(ProviderBridge.route(for: provider, key: "sk-1"))
        #expect(route.usesAPIKeyHeader && route.apiKey == "sk-1")
        #expect(route.extraHeaders["X-Org"] == "abc" && route.extraHeaders["X-Token"] == "t")
        let gateway = try #require(URL(string: "http://127.0.0.1:9/t"))
        let meta = ProviderLaunch.sessionMeta(ModelProviderTests.mapping(provider, "m1", key: "sk-1"), gateway: gateway)
        let text = String(describing: meta)
        #expect(!text.contains("sk-1") && !text.contains("X-Org"))
        #expect(meta["claudeCode"]?["options"]?["env"]?["ANTHROPIC_API_KEY"] == nil)
    }

    @Test("校验:非法数值、强度与请求头")
    func validation() {
        var provider = base()
        provider.maxOutputTokens = 0
        #expect(throws: ModelProvider.ValidationError.invalidNumber("最大输出 token")) { try provider.validate() }
        provider = base()
        provider.effort = "extreme"
        #expect(throws: ModelProvider.ValidationError.invalidEffort) { try provider.validate() }
        provider = base()
        provider.customHeaders = "没有冒号"
        #expect(throws: ModelProvider.ValidationError.invalidHeaders) { try provider.validate() }
        provider.customHeaders = "A: b"
        #expect(throws: Never.self) { try provider.validate() }
    }

    @Test("旧版 providers.json(无新字段、含 active)仍可解码")
    func backwardCompatible() throws {
        let json = #"{"active":"p","providers":[{"id":"p","name":"P","baseURL":"https://x.com","model":"m"}]}"#
        let snapshot = try JSONDecoder().decode(ProviderSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.providers.first?.maxOutputTokens == nil)
        #expect(snapshot.providers.first?.availableModels == nil)
    }

    @Test("OpenCode Zen 预设使用 x-api-key 并带兼容头;旧数据加载时补齐")
    func opencodePreset() throws {
        let fresh = try #require(ProviderPreset.all.first { $0.id == "opencode" }).makeProvider()
        #expect(fresh.usesAPIKeyHeader == true && fresh.opencodeCompat == true)
        let old = ModelProvider(id: "opencode", name: "OpenCode Zen", baseURL: "https://opencode.ai/zen", model: "m", presetId: "opencode")
        let migrated = old.migrated()
        #expect(migrated.usesAPIKeyHeader == true && migrated.opencodeCompat == true)
        let route = try #require(ProviderBridge.route(for: migrated, key: "k"))
        #expect(route.usesAPIKeyHeader && route.extraHeaders["User-Agent"]?.hasPrefix("OhMyAgent/") == true && route.extraHeaders["x-opencode-session"]?.hasPrefix("ses_") == true)
        // 用户显式关闭过的不覆盖
        var custom = old
        custom.usesAPIKeyHeader = false
        #expect(custom.migrated().usesAPIKeyHeader == false)
    }

    @Test("映射解析:不同提供商可混用到不同槽位")
    func mixedProviders() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-prov-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var a = base(); a.id = "a"; a.name = "A"
        var b = base(); b.id = "b"; b.name = "B"; b.model = "bm"
        let mapping = ModelMapping(slots: [.main: ModelTarget(providerId: "a", model: "m1"), .opus: ModelTarget(providerId: "b", model: "bm"), .subagent: ModelTarget(providerId: "b", model: "bs")])
        try ProviderStorage.save(ProviderSnapshot(mapping: mapping, providers: [a, b]), directory: dir)
        try ProviderStorage.setKey("ka", for: "a", directory: dir)
        try ProviderStorage.setKey("kb", for: "b", directory: dir)
        let resolved = try #require(try ProviderStorage.resolveMapping(directory: dir, environment: [:]))
        #expect(resolved.main.provider.id == "a" && resolved.others[.opus]?.provider.id == "b")
        #expect(resolved.infos[.subagent]?.modelId == "bs")
        let gateway = try #require(URL(string: "http://127.0.0.1:9/t"))
        let env = ProviderLaunch.publicEnvironment(resolved, gateway: gateway)
        #expect(env["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "oma-large" && env["CLAUDE_CODE_SUBAGENT_MODEL"] == "oma-sub")
    }

    @Test("来源开关:关闭后不解析映射但保留内容;旧文件默认启用;已配置信息仍可展示")
    func useMappingSwitch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-prov-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mapping = ModelMapping(slots: [.main: ModelTarget(providerId: "p", model: "m1"), .opus: ModelTarget(providerId: "p", model: "m2")])
        try ProviderStorage.save(ProviderSnapshot(mapping: mapping, providers: [base()]), directory: dir)
        try ProviderStorage.setKey("k", for: "p", directory: dir)
        #expect(ProviderStorage.load(directory: dir).useMapping)
        #expect(try ProviderStorage.resolveMapping(directory: dir, environment: [:]) != nil)

        try ProviderStorage.setUseMapping(false, directory: dir)
        #expect(!ProviderStorage.load(directory: dir).useMapping)
        #expect(try ProviderStorage.resolveMapping(directory: dir, environment: [:]) == nil)
        // 关闭后映射内容仍在,展示信息未设置的槽位沿用默认槽位
        let infos = ProviderStorage.configuredInfos(directory: dir)
        #expect(infos[.main]?.modelId == "m1" && infos[.opus]?.modelId == "m2" && infos[.sonnet]?.modelId == "m1")
        #expect(infos[.subagent] == nil)

        try ProviderStorage.setUseMapping(true, directory: dir)
        #expect(try ProviderStorage.resolveMapping(directory: dir, environment: [:]) != nil)
    }

    @Test("来源开关:旧 providers.json 无 useMapping 字段时默认启用;未配置映射时展示信息为空")
    func useMappingLegacyDefault() throws {
        let data = Data(#"{"providers":[],"mapping":{}}"#.utf8)
        #expect(try JSONDecoder().decode(ProviderSnapshot.self, from: data).useMapping)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-prov-\(UUID().uuidString)")
        #expect(ProviderStorage.configuredInfos(directory: dir).isEmpty)
    }

    @Test("模型列表解析:data / models / 字符串数组,去重保序")
    func parseModels() {
        #expect(ProviderModelFetcher.parse(Data(#"{"data":[{"id":"a"},{"id":"b"},{"id":"a"}]}"#.utf8)) == ["a", "b"])
        #expect(ProviderModelFetcher.parse(Data(#"{"models":["x","y"]}"#.utf8)) == ["x", "y"])
        #expect(ProviderModelFetcher.parse(Data(#"["m"]"#.utf8)) == ["m"])
        #expect(ProviderModelFetcher.parse(Data("oops".utf8)).isEmpty)
    }

    @Test("预设:包含 Anthropic 官方与 OpenCode,官方使用 x-api-key")
    func newPresets() throws {
        let official = try #require(ProviderPreset.all.first { $0.id == "anthropic" })
        #expect(official.makeProvider().usesAPIKeyHeader == true)
        #expect(ProviderPreset.all.contains { $0.id == "opencode" })
        #expect(ProviderPreset.all.count >= 7)
        for item in ProviderPreset.all { #expect(throws: Never.self) { try item.makeProvider().validate() } }
    }
}

/// 模型列表获取:放进「提供商连接测试」套件(共享串行的 URL 桩,避免并行互相覆盖)。
extension ProviderTesterTests {
    @Test("成功:带 Bearer 或 x-api-key 头请求 /v1/models")
    func fetchSuccess() async {
        nonisolated(unsafe) var seenAuth: String?
        nonisolated(unsafe) var seenKey: String?
        StubURLProtocol.handler = { request in
            seenAuth = request.value(forHTTPHeaderField: "Authorization")
            seenKey = request.value(forHTTPHeaderField: "x-api-key")
            return (200, Data(#"{"data":[{"id":"m1"},{"id":"m2"}]}"#.utf8))
        }
        let session = Self.session()
        var provider = ModelProvider(id: "p", name: "P", baseURL: "https://x.com/anthropic", model: "m")
        let bearer = await ProviderModelFetcher.fetch(provider, key: "sk", session: session)
        #expect((try? bearer.get()) == ["m1", "m2"])
        #expect(seenAuth == "Bearer sk" && seenKey == nil)
        provider.usesAPIKeyHeader = true
        _ = await ProviderModelFetcher.fetch(provider, key: "sk", session: session)
        #expect(seenKey == "sk")
    }

    @Test("失败:缺密钥、鉴权失败")
    func fetchFailure() async {
        let provider = ModelProvider(id: "p", name: "P", baseURL: "https://x.com", model: "m")
        let missing = await ProviderModelFetcher.fetch(provider, key: " ", session: Self.session())
        if case .failure(let error) = missing { #expect(error.message.contains("API Key")) } else { Issue.record("应失败") }
        StubURLProtocol.handler = { _ in (401, Data()) }
        let denied = await ProviderModelFetcher.fetch(provider, key: "bad", session: Self.session())
        if case .failure(let error) = denied { #expect(error.message.contains("鉴权失败")) } else { Issue.record("应失败") }
    }
}

@Suite("OpenCode 会话头")
struct OpenCodeSessionHeaderTests {
    @Test("同一会话键的会话 id 恒定,不同键不同;格式为 ses_ + 24 位十六进制")
    func stableSession() {
        let a1 = ProviderBridge.opencodeSessionID(for: "chat-a")
        let a2 = ProviderBridge.opencodeSessionID(for: "chat-a")
        let b = ProviderBridge.opencodeSessionID(for: "chat-b")
        #expect(a1 == a2 && a1 != b)
        #expect(a1.hasPrefix("ses_") && a1.count == 28)
        #expect(ProviderBridge.opencodeSessionID(for: "") != ProviderBridge.opencodeSessionID(for: ""), "空键为一次性随机 id")
    }

    @Test("兼容头使用自有 UA,不伪装成 opencode 官方客户端")
    func ownUserAgent() {
        let headers = ProviderBridge.opencodeHeaders(sessionKey: "k")
        #expect(headers["User-Agent"]?.hasPrefix("OhMyAgent/") == true)
        #expect(headers["x-opencode-session"] == ProviderBridge.opencodeSessionID(for: "k"))
        #expect(headers.keys.allSatisfy { $0 == "User-Agent" || $0 == "x-opencode-session" })
    }

    @Test("路由按会话键派生会话头;两种协议的测试请求都带兼容头")
    func routeAndTesterHeaders() throws {
        var provider = ModelProvider(id: "o", name: "O", baseURL: "https://opencode.ai/zen/go/v1", model: "m", protocolKind: .openai, opencodeCompat: true)
        let route1 = try #require(ProviderBridge.route(for: provider, key: "k", sessionKey: "chat-a"))
        let route2 = try #require(ProviderBridge.route(for: provider, key: "k", sessionKey: "chat-b"))
        #expect(route1.extraHeaders["x-opencode-session"] != route2.extraHeaders["x-opencode-session"])
        for kind in [ProviderProtocol.openai, .anthropic] {
            provider.protocolKind = kind == .openai ? .openai : nil
            var request = URLRequest(url: try #require(URL(string: "https://opencode.ai/x")))
            ProviderTester.applyAuth(&request, provider: provider, key: "k")
            #expect(request.value(forHTTPHeaderField: "x-opencode-session") != nil)
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("OhMyAgent/") == true)
        }
    }

    @Test("旧「Zen 免费模型」预设迁移到 Go 端点;错误码有可操作提示")
    func freePresetMigration() {
        let old = ModelProvider(id: "f", name: "F", baseURL: "https://opencode.ai/zen/v1/", model: "big-pickle", presetId: "opencode-free", protocolKind: .openai, keyOptional: true)
        let migrated = old.migrated()
        #expect(migrated.baseURL == "https://opencode.ai/zen/go/v1" && migrated.requiresKey && migrated.opencodeCompat == true)
        #expect(ProviderTester.describe(status: 403, body: Data(#"{"error":{"type":"FreeTierError"}}"#.utf8)).contains("OpenCode Go"))
        #expect(ProviderTester.describe(status: 400, body: Data(#"{"error":{"type":"MissingSessionID"}}"#.utf8)).contains("x-opencode-session"))
        #expect(ProviderTester.describe(status: 400, body: Data(#"{"error":{"type":"ModelProtocolUnsupported"}}"#.utf8)).contains("协议"))
    }
}
