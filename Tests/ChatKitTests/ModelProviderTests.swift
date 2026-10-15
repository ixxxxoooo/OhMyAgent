// @author ygw
// 模型提供商:会话 `_meta` 生成(密钥只进 env)、校验、存储与权限、连接测试。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

/// 拦截 URLSession 请求的桩协议。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: status, httpVersion: nil, headerFields: nil)
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("模型提供商")
struct ModelProviderTests {
    static let deepseek = ModelProvider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/anthropic/", model: "deepseek-chat", haikuModel: "deepseek-lite")

    static func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-prov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("校验:名称/地址/模型")
    func validation() {
        #expect(throws: ModelProvider.ValidationError.emptyName) { try ModelProvider(id: "a", name: " ", baseURL: "https://x.com", model: "m").validate() }
        #expect(throws: ModelProvider.ValidationError.invalidBaseURL) { try ModelProvider(id: "a", name: "A", baseURL: "ftp://x", model: "m").validate() }
        #expect(throws: ModelProvider.ValidationError.invalidBaseURL) { try ModelProvider(id: "a", name: "A", baseURL: "nope", model: "m").validate() }
        #expect(throws: ModelProvider.ValidationError.emptyModel) { try ModelProvider(id: "a", name: "A", baseURL: "https://x.com", model: "").validate() }
        #expect(throws: Never.self) { try Self.deepseek.validate() }
        #expect(Self.deepseek.normalizedBaseURL == "https://api.deepseek.com/anthropic")
    }

    @Test("非密钥环境:设置地址与各角色模型并清空用户侧变量")
    func publicEnvironment() {
        let env = ProviderLaunch.publicEnvironment(Self.deepseek)
        #expect(env["ANTHROPIC_BASE_URL"] == "https://api.deepseek.com/anthropic")
        #expect(env["ANTHROPIC_MODEL"] == "deepseek-chat")
        #expect(env["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "deepseek-chat")
        #expect(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "deepseek-lite")
        #expect(env["ANTHROPIC_API_KEY"] == "")
        for name in ProviderLaunch.clearedVariables { #expect(env[name] == "") }
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == nil)
    }

    @Test("_meta:密钥只在进程 env,不在 settings")
    func metaKeepsKeyOutOfSettings() throws {
        let meta = ProviderLaunch.sessionMeta(Self.deepseek, key: "sk-test-secret-123456789012345")
        let options = try #require(meta["claudeCode"]?["options"])
        let settings = try #require(options["settings"])
        #expect(settings["model"]?.stringValue == "deepseek-chat")
        #expect(settings["apiKeyHelper"]?.stringValue == "")
        #expect(options["env"]?["ANTHROPIC_AUTH_TOKEN"]?.stringValue == "sk-test-secret-123456789012345")
        let settingsText = String(describing: settings)
        #expect(!settingsText.contains("sk-test-secret"))
    }

    @Test("存储往返、密钥权限 0600、删除密钥")
    func storageRoundTrip() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProviderStorage.save(ProviderSnapshot(active: "deepseek", providers: [Self.deepseek]), directory: dir)
        #expect(ProviderStorage.load(directory: dir).providers == [Self.deepseek])
        try ProviderStorage.setKey("  sk-abc  ", for: "deepseek", directory: dir)
        #expect(ProviderStorage.key(for: "deepseek", directory: dir, environment: [:]) == "sk-abc")
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("provider-keys.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try ProviderStorage.setKey("", for: "deepseek", directory: dir)
        #expect(ProviderStorage.key(for: "deepseek", directory: dir, environment: [:]) == nil)
    }

    @Test("环境变量 OMA_PROVIDER_KEY 优先;损坏文件回退为空")
    func envOverrideAndCorruption() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ProviderStorage.key(for: "x", directory: dir, environment: ["OMA_PROVIDER_KEY": "sk-env"]) == "sk-env")
        try "{坏的".write(to: dir.appendingPathComponent("providers.json"), atomically: true, encoding: .utf8)
        #expect(ProviderStorage.load(directory: dir) == ProviderSnapshot())
    }

    @Test("resolveActive:未启用返回 nil;缺密钥与配置无效抛错;齐全时返回 meta")
    func resolveActive() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try ProviderStorage.resolveActive(directory: dir, environment: [:]) == nil)
        try ProviderStorage.save(ProviderSnapshot(active: "deepseek", providers: [Self.deepseek]), directory: dir)
        #expect(throws: ProviderStorage.ResolveError.missingKey("DeepSeek")) { try ProviderStorage.resolveActive(directory: dir, environment: [:]) }
        try ProviderStorage.setKey("sk-ok", for: "deepseek", directory: dir)
        let resolved = try #require(try ProviderStorage.resolveActive(directory: dir, environment: [:]))
        #expect(resolved.provider.id == "deepseek")
        #expect(resolved.meta["claudeCode"]?["options"]?["env"]?["ANTHROPIC_AUTH_TOKEN"]?.stringValue == "sk-ok")
        var bad = Self.deepseek
        bad.baseURL = "bad"
        try ProviderStorage.save(ProviderSnapshot(active: "deepseek", providers: [bad]), directory: dir)
        #expect(throws: (any Error).self) { try ProviderStorage.resolveActive(directory: dir, environment: [:]) }
    }

    @Test("预设:DeepSeek 使用 /anthropic 端点")
    func presets() throws {
        let preset = try #require(ProviderPreset.all.first { $0.id == "deepseek" })
        #expect(preset.baseURL.hasSuffix("/anthropic"))
        #expect(preset.makeProvider().model == "deepseek-chat")
        for item in ProviderPreset.all { #expect(throws: Never.self) { try item.makeProvider().validate() } }
    }
}

@Suite("提供商连接测试", .serialized)
struct ProviderTesterTests {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("成功:返回耗时与回复,并带 Bearer 与版本头")
    func success() async {
        let captured = LockedBox<URLRequest?>(nil)
        StubURLProtocol.handler = { request in
            captured.value = request
            return (200, Data(#"{"content":[{"type":"text","text":"pong"}]}"#.utf8))
        }
        let result = await ProviderTester.test(ModelProviderTests.deepseek, key: "sk-1", session: Self.session())
        guard case .ok(_, let reply) = result else { Issue.record("应成功:\(result)"); return }
        #expect(reply == "pong")
        #expect(captured.value?.url?.absoluteString == "https://api.deepseek.com/anthropic/v1/messages")
        #expect(captured.value?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        #expect(captured.value?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test("401/404/429 被翻译为可操作提示,且错误信息不含密钥")
    func statusMapping() async {
        for (status, keyword) in [(401, "鉴权"), (404, "不存在"), (429, "限流")] {
            StubURLProtocol.handler = { _ in (status, Data(#"{"error":"bad key sk-leakleakleakleakleakleak"}"#.utf8)) }
            let result = await ProviderTester.test(ModelProviderTests.deepseek, key: "sk-1", session: Self.session())
            guard case .failed(let message) = result else { Issue.record("应失败"); continue }
            #expect(message.contains(keyword))
            #expect(!message.contains("sk-leak"))
        }
    }

    @Test("缺密钥或地址无效时不发请求")
    func preconditions() async {
        StubURLProtocol.handler = { _ in (200, Data()) }
        #expect(await ProviderTester.test(ModelProviderTests.deepseek, key: " ", session: Self.session()) == .failed("未填写 API Key"))
        var bad = ModelProviderTests.deepseek
        bad.baseURL = "x"
        if case .failed = await ProviderTester.test(bad, key: "k", session: Self.session()) {} else { Issue.record("应失败") }
    }
}

/// 线程安全的盒子(测试里捕获请求)。
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
