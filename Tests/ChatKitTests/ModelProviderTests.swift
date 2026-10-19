// @author ixxxxoooo
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

    /// 构造只含默认槽位的已解析映射(测试用)。
    static func mapping(_ provider: ModelProvider, _ model: String, key: String = "k") -> ResolvedMapping {
        ResolvedMapping(main: target(provider, model, .main, key: key), others: [:], warnings: [])
    }

    static func target(_ provider: ModelProvider, _ model: String, _ slot: ModelSlot, key: String = "k") -> ResolvedTarget {
        ResolvedTarget(slot: slot, provider: provider, model: model, key: key)
    }

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

    @Test("非密钥环境:经本机网关,槽位用别名,清空用户侧变量")
    func publicEnvironment() throws {
        let gateway = try #require(URL(string: "http://127.0.0.1:9/tok"))
        var mapping = Self.mapping(Self.deepseek, "deepseek-chat")
        mapping.others[.haiku] = Self.target(Self.deepseek, "deepseek-lite", .haiku)
        let env = ProviderLaunch.publicEnvironment(mapping, gateway: gateway)
        #expect(env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:9/tok")
        #expect(env["ANTHROPIC_MODEL"] == "oma-main")
        #expect(env["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "oma-main", "未设置的槽位沿用默认槽位")
        #expect(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "oma-small")
        #expect(env["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"] == "deepseek-lite")
        #expect(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"] == "deepseek-chat")
        #expect(env["CLAUDE_CODE_SUBAGENT_MODEL"] == "")
        for name in ProviderLaunch.clearedVariables { #expect(env[name] == "") }
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == nil)
        for alias in ModelSlot.allCases.map(\.alias) { for word in ["opus", "sonnet", "haiku"] { #expect(!alias.contains(word)) } }
    }

    @Test("_meta:只含占位令牌与本机地址,真实密钥与上游地址都不出现")
    func metaKeepsKeyOutOfSettings() throws {
        let gateway = try #require(URL(string: "http://127.0.0.1:9/tok"))
        let meta = ProviderLaunch.sessionMeta(Self.mapping(Self.deepseek, "deepseek-chat", key: "sk-test-secret-123456789012345"), gateway: gateway)
        let options = try #require(meta["claudeCode"]?["options"])
        let settings = try #require(options["settings"])
        #expect(settings["model"]?.stringValue == "oma-main")
        #expect(settings["apiKeyHelper"]?.stringValue == "")
        #expect(options["env"]?["ANTHROPIC_AUTH_TOKEN"]?.stringValue == ProviderLaunch.placeholderToken)
        let text = String(describing: meta)
        #expect(!text.contains("sk-test-secret"))
        #expect(!text.contains("deepseek.com"))
    }

    @Test("存储往返、密钥权限 0600、删除密钥")
    func storageRoundTrip() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProviderStorage.save(ProviderSnapshot(mapping: ModelMapping(slots: [.main: ModelTarget(providerId: "deepseek", model: "deepseek-chat")]), providers: [Self.deepseek]), directory: dir)
        #expect(ProviderStorage.load(directory: dir).mapping[.main]?.model == "deepseek-chat")
        #expect(ProviderStorage.load(directory: dir).providers == [Self.deepseek])
        try ProviderStorage.setKey("  sk-abc  ", for: "deepseek", directory: dir)
        #expect(ProviderStorage.key(for: "deepseek", directory: dir, environment: [:]) == "sk-abc")
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("provider-keys.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try ProviderStorage.setKey("", for: "deepseek", directory: dir)
        #expect(ProviderStorage.key(for: "deepseek", directory: dir, environment: [:]) == nil)
    }

    @Test("密钥文件损坏时写入抛错且保留原文件,不抹掉其他提供商的密钥")
    func corruptKeyFileIsNotOverwritten() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provider-keys.json")
        let corrupt = Data("{\"deepseek\": \"sk-a".utf8)
        try corrupt.write(to: url)
        #expect(throws: (any Error).self) { try ProviderStorage.setKey("sk-new", for: "glm", directory: dir) }
        #expect(try Data(contentsOf: url) == corrupt)
        // 正常文件:写入新提供商不影响已有密钥,临时文件不残留
        try FileManager.default.removeItem(at: url)
        try ProviderStorage.setKey("sk-a", for: "deepseek", directory: dir)
        try ProviderStorage.setKey("sk-b", for: "glm", directory: dir)
        #expect(ProviderStorage.key(for: "deepseek", directory: dir, environment: [:]) == "sk-a")
        #expect(ProviderStorage.key(for: "glm", directory: dir, environment: [:]) == "sk-b")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("环境变量 OMA_PROVIDER_KEY 优先;损坏文件回退为空")
    func envOverrideAndCorruption() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ProviderStorage.key(for: "x", directory: dir, environment: ["OMA_PROVIDER_KEY": "sk-env"]) == "sk-env")
        try "{坏的".write(to: dir.appendingPathComponent("providers.json"), atomically: true, encoding: .utf8)
        #expect(ProviderStorage.load(directory: dir) == ProviderSnapshot())
    }

    @Test("resolveMapping:未设置返回 nil;缺密钥/停用/配置无效抛错;齐全时解析各槽位")
    func resolveMapping() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try ProviderStorage.resolveMapping(directory: dir, environment: [:]) == nil)
        let mapping = ModelMapping(slots: [.main: ModelTarget(providerId: "deepseek", model: "deepseek-chat")])
        try ProviderStorage.save(ProviderSnapshot(mapping: mapping, providers: [Self.deepseek]), directory: dir)
        #expect(throws: ProviderStorage.ResolveError.missingKey("DeepSeek")) { try ProviderStorage.resolveMapping(directory: dir, environment: [:]) }
        try ProviderStorage.setKey("sk-ok", for: "deepseek", directory: dir)
        let resolved = try #require(try ProviderStorage.resolveMapping(directory: dir, environment: [:]))
        #expect(resolved.main.provider.id == "deepseek" && resolved.main.key == "sk-ok" && resolved.warnings.isEmpty)
        var bad = Self.deepseek
        bad.baseURL = "bad"
        try ProviderStorage.save(ProviderSnapshot(mapping: mapping, providers: [bad]), directory: dir)
        #expect(throws: (any Error).self) { try ProviderStorage.resolveMapping(directory: dir, environment: [:]) }
        var off = Self.deepseek
        off.enabled = false
        try ProviderStorage.save(ProviderSnapshot(mapping: mapping, providers: [off]), directory: dir)
        #expect(throws: ProviderStorage.ResolveError.disabled("DeepSeek")) { try ProviderStorage.resolveMapping(directory: dir, environment: [:]) }
    }

    @Test("非默认槽位的提供商不可用时只产生警告并退回默认槽位")
    func slotFallbackWarning() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = ModelProvider(id: "other", name: "Other", baseURL: "https://o.com/anthropic", model: "o1")
        let mapping = ModelMapping(slots: [.main: ModelTarget(providerId: "deepseek", model: "deepseek-chat"),
                                           .haiku: ModelTarget(providerId: "other", model: "o1")])
        try ProviderStorage.save(ProviderSnapshot(mapping: mapping, providers: [Self.deepseek, other]), directory: dir)
        try ProviderStorage.setKey("sk-ok", for: "deepseek", directory: dir)
        let resolved = try #require(try ProviderStorage.resolveMapping(directory: dir, environment: [:]))
        #expect(resolved.others.isEmpty && resolved.warnings.count == 1)
        #expect(resolved.infos.keys.sorted { $0.rawValue < $1.rawValue } == [.main])
    }

    @Test("旧版 active + Opus/Sonnet/Haiku 角色模型迁移为映射")
    func migrateLegacyActive() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"active":"deepseek","providers":[{"id":"deepseek","name":"DeepSeek","baseURL":"https://api.deepseek.com/anthropic","model":"deepseek-chat","haikuModel":"deepseek-lite"}]}"#
        try json.write(to: dir.appendingPathComponent("providers.json"), atomically: true, encoding: .utf8)
        let snapshot = ProviderStorage.load(directory: dir)
        #expect(snapshot.mapping[.main] == ModelTarget(providerId: "deepseek", model: "deepseek-chat"))
        #expect(snapshot.mapping[.haiku] == ModelTarget(providerId: "deepseek", model: "deepseek-lite"))
        #expect(snapshot.mapping[.opus] == nil)
        // 迁移结果落盘后不再含旧的 active 字段
        try ProviderStorage.save(snapshot, directory: dir)
        let text = try String(contentsOf: dir.appendingPathComponent("providers.json"), encoding: .utf8)
        #expect(!text.contains("\"active\""))
    }

    @Test("槽位别名与选项值互相映射;删除提供商会清除指向它的映射")
    func slotsAndRemoval() {
        #expect(ModelSlot(optionValue: "opus") == .opus && ModelSlot(optionValue: "default") == .main && ModelSlot(optionValue: "fable") == nil)
        #expect(Set(ModelSlot.allCases.map(\.alias)).count == ModelSlot.allCases.count)
        var mapping = ModelMapping(slots: [.main: ModelTarget(providerId: "a", model: "m"), .haiku: ModelTarget(providerId: "b", model: "n")])
        mapping.removeTargets(of: "a")
        #expect(mapping[.main] == nil && mapping[.haiku] != nil)
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
