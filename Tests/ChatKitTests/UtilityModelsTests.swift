// @author ixxxxoooo
// 辅助任务模型:偏好值编解码、网关入口解析与回退。

import Foundation
import ProviderProxyKit
import Testing
@testable import ChatKit

@Suite("辅助任务模型")
struct UtilityModelsTests {
    private let fallback = (url: URL(string: "http://127.0.0.1:1/session")!, alias: "oma-small")

    @Test("偏好值往返:空串为自动,off 为关闭,指定模型保留提供商与模型 ID")
    func rawRoundTrip() {
        #expect(UtilityModelChoice(raw: nil) == .automatic)
        #expect(UtilityModelChoice(raw: "") == .automatic)
        #expect(UtilityModelChoice(raw: "off") == .off)
        let choice = UtilityModelChoice.model(providerId: "ds", model: "deepseek-chat")
        #expect(UtilityModelChoice(raw: choice.raw) == choice)
        #expect(UtilityModelChoice(raw: "garbage") == .automatic)
        #expect(UtilityModelChoice(raw: "ds\u{1F}") == .automatic)
    }

    @Test("读取任务偏好")
    func readsPreference() {
        let suite = "oma-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        #expect(UtilityModels.choice(for: .title, defaults: defaults) == .automatic)
        defaults.set("off", forKey: UtilityTask.title.preferenceKey)
        defaults.set(UtilityModelChoice.model(providerId: "a", model: "m").raw, forKey: UtilityTask.optimize.preferenceKey)
        #expect(UtilityModels.choice(for: .title, defaults: defaults) == .off)
        #expect(UtilityModels.choice(for: .optimize, defaults: defaults) == .model(providerId: "a", model: "m"))
    }

    @Test("自动与关闭:自动用回退入口,关闭不发请求")
    func automaticAndOff() async {
        let auto = await UtilityModels.endpoint(for: .automatic, fallback: fallback)
        #expect(auto?.alias == "oma-small")
        #expect(await UtilityModels.endpoint(for: .off, fallback: fallback) == nil)
        #expect(await UtilityModels.endpoint(for: .automatic, fallback: nil) == nil)
    }

    @Test("指定模型不可用(提供商缺失/缺密钥)时回退到会话入口")
    func unavailableFallsBack() async throws {
        let directory = try ModelProviderTests.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = ProviderProxy()
        let missing = UtilityModelChoice.model(providerId: "nope", model: "m")
        #expect(await UtilityModels.endpoint(for: missing, fallback: fallback, directory: directory, environment: [:], proxy: proxy)?.alias == "oma-small")
        let provider = ModelProvider(id: "oa", name: "OA", baseURL: "https://api.example.com/v1", model: "gpt", protocolKind: .openai)
        try ProviderStorage.save(ProviderSnapshot(providers: [provider]), directory: directory)
        let noKey = UtilityModelChoice.model(providerId: "oa", model: "gpt")
        #expect(await UtilityModels.endpoint(for: noKey, fallback: fallback, directory: directory, environment: [:], proxy: proxy)?.alias == "oma-small")
        await proxy.shutdown()
    }

    @Test("指定模型可用时注册独立路由,地址不含真实密钥")
    func registersRoute() async throws {
        let directory = try ModelProviderTests.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = ProviderProxy()
        let provider = ModelProvider(id: "oa", name: "OA", baseURL: "https://api.example.com/v1", model: "gpt", protocolKind: .openai)
        try ProviderStorage.save(ProviderSnapshot(providers: [provider]), directory: directory)
        try ProviderStorage.setKey("sk-real-secret", for: "oa", directory: directory)
        let choice = UtilityModelChoice.model(providerId: "oa", model: "gpt-mini")
        let endpoint = try #require(await UtilityModels.endpoint(for: choice, fallback: fallback, directory: directory, environment: [:], proxy: proxy))
        #expect(endpoint.alias == UtilityModels.alias)
        #expect(endpoint.url.host == "127.0.0.1")
        #expect(!endpoint.url.absoluteString.contains("sk-real-secret"))
        // 同一提供商 + 模型重复解析沿用同一路由地址
        let again = try #require(await UtilityModels.endpoint(for: choice, fallback: fallback, directory: directory, environment: [:], proxy: proxy))
        #expect(again.url == endpoint.url)
        await proxy.shutdown()
    }
}
