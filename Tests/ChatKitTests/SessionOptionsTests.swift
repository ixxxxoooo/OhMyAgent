// @author ixxxxoooo
// 客户端会话选项:环境变量生成、与提供商 `_meta` 的合并规则。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@Suite("会话选项")
struct SessionOptionsTests {
    private func defaults() -> UserDefaults {
        let suite = "oma-test-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite) ?? .standard
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test("默认选项不改变 _meta")
    func defaultIsNoop() {
        let options = SessionOptions()
        #expect(options.isDefault)
        #expect(options.merged(into: nil) == nil)
        let base: JSONValue = .object(["a": .int(1)])
        #expect(options.merged(into: base) == base)
    }

    @Test("HTTP 代理与超时生成环境变量")
    func httpProxyEnv() {
        var options = SessionOptions()
        options.proxyMode = .http
        options.proxyAddress = "127.0.0.1:7890"
        options.timeoutSeconds = 30
        #expect(options.environment["HTTPS_PROXY"] == "http://127.0.0.1:7890")
        #expect(options.environment["http_proxy"] == "http://127.0.0.1:7890")
        #expect(options.environment["API_TIMEOUT_MS"] == "30000")
    }

    @Test("SOCKS5 与直连")
    func socksAndOff() {
        var options = SessionOptions()
        options.proxyMode = .socks5
        options.proxyAddress = "localhost:1080"
        #expect(options.environment["ALL_PROXY"] == "socks5://localhost:1080")
        options.proxyMode = .off
        #expect(options.environment["HTTPS_PROXY"] == "")
        #expect(options.environment["NO_PROXY"] == "*")
        options.proxyMode = .http
        options.proxyAddress = "  "
        #expect(options.environment.isEmpty)
    }

    @Test("关闭 CLAUDE.md 与追加提示词")
    func memoryAndPrompt() {
        var options = SessionOptions()
        options.loadClaudeMemory = false
        options.appendPrompt = "  请用中文回答  \n"
        #expect(options.environment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] == "1")
        let meta = options.merged(into: nil)
        guard case .object(let root)? = meta, case .object(let prompt)? = root["systemPrompt"] else {
            Issue.record("缺少 systemPrompt")
            return
        }
        #expect(prompt["append"] == .string("请用中文回答"))
    }

    @Test("合并时保留提供商的变量,且提供商已设置的键不被覆盖")
    func mergeKeepsProvider() {
        let base: JSONValue = .object(["claudeCode": .object(["options": .object([
            "settings": .object(["model": .string("m")]),
            "env": .object(["ANTHROPIC_AUTH_TOKEN": .string("secret"), "API_TIMEOUT_MS": .string("1")]),
        ])])])
        var options = SessionOptions()
        options.timeoutSeconds = 5
        options.proxyMode = .http
        options.proxyAddress = "h:1"
        guard case .object(let root)? = options.merged(into: base),
              case .object(let code)? = root["claudeCode"], case .object(let opts)? = code["options"],
              case .object(let env)? = opts["env"] else {
            Issue.record("合并结果结构错误")
            return
        }
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == .string("secret"))
        #expect(env["API_TIMEOUT_MS"] == .string("1"))
        #expect(env["HTTPS_PROXY"] == .string("http://h:1"))
        #expect(opts["settings"] != nil)
    }

    @Test("从偏好读取并容错")
    func loadFromDefaults() {
        let store = defaults()
        store.set("socks5", forKey: ClientPrefs.Key.proxyMode)
        store.set("a:1", forKey: ClientPrefs.Key.proxyAddress)
        store.set(-5, forKey: ClientPrefs.Key.requestTimeout)
        let options = SessionOptions(defaults: store)
        #expect(options.proxyMode == .socks5)
        #expect(options.timeoutSeconds == 0)
        #expect(options.loadClaudeMemory)
        store.set("bogus", forKey: ClientPrefs.Key.proxyMode)
        #expect(SessionOptions(defaults: store).proxyMode == .system)
    }

    @Test("发送键、运行中发送与聊天宽度默认值")
    func prefsDefaults() {
        let store = defaults()
        #expect(ClientPrefs.sendKey(store) == .enter)
        #expect(ClientPrefs.runningSendMode(store) == .steer)
        #expect(ClientPrefs.notifiesWithSound(store))
        store.set("commandEnter", forKey: ClientPrefs.Key.sendKey)
        store.set("queue", forKey: ClientPrefs.Key.runningSend)
        #expect(ClientPrefs.sendKey(store) == .commandEnter)
        #expect(ClientPrefs.runningSendMode(store) == .queue)
        #expect(ChatWidth.narrow.points < ChatWidth.standard.points)
        #expect(ChatWidth.full.points == .infinity)
    }
}
