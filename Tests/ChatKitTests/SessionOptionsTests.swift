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

@Suite("聊天宽度档位")
struct ChatWidthTests {
    @Test("档位单调递增,铺满不限制")
    func monotonic() {
        let presets: [ChatWidth] = [.compact, .narrow, .standard, .comfortable, .wide, .ultra]
        let points = presets.map(\.points)
        #expect(points == points.sorted())
        #expect(Set(points).count == points.count)
        #expect(ChatWidth.full.points == .infinity)
    }

    @Test("旧存储值保持兼容,未知值回退标准")
    func legacy() {
        #expect(ChatWidth.resolve(raw: "narrow", custom: 900) == 680)
        #expect(ChatWidth.resolve(raw: "standard", custom: 900) == 820)
        #expect(ChatWidth.resolve(raw: "wide", custom: 900) == 1000)
        #expect(ChatWidth.resolve(raw: "full", custom: 900) == .infinity)
        #expect(ChatWidth.resolve(raw: "乱写", custom: 900) == 820)
    }

    @Test("自定义宽度夹到范围并对齐步长,非有限值回退默认")
    func custom() {
        #expect(ChatWidth.resolve(raw: "custom", custom: 905) == 900)
        #expect(ChatWidth.resolve(raw: "custom", custom: 10) == 480)
        #expect(ChatWidth.resolve(raw: "custom", custom: 99_999) == 1600)
        #expect(ChatWidth.clampedCustom(.nan) == ChatWidth.customDefault)
        #expect(ChatWidth.clampedCustom(.infinity) == ChatWidth.customDefault)
    }
}

@Suite("设置页内容宽度档位")
struct SettingsContentWidthTests {
    @Test("档位单调递增,铺满不限制,未知值回退标准")
    func presets() {
        let presets: [SettingsContentWidth] = [.compact, .standard, .wide]
        let points = presets.map(\.points)
        #expect(points == points.sorted())
        #expect(Set(points).count == points.count)
        #expect(SettingsContentWidth.full.points == .infinity)
        #expect(SettingsContentWidth.resolve(raw: "乱写", custom: 900) == SettingsContentWidth.standard.points)
    }

    @Test("自定义宽度夹到范围并对齐步长,非有限值回退默认")
    func custom() {
        #expect(SettingsContentWidth.resolve(raw: "custom", custom: 905) == 900)
        #expect(SettingsContentWidth.resolve(raw: "custom", custom: 10) == 560)
        #expect(SettingsContentWidth.resolve(raw: "custom", custom: 99_999) == 1600)
        #expect(SettingsContentWidth.clampedCustom(.nan) == SettingsContentWidth.customDefault)
    }
}

@Suite("宽度滑块档位")
struct WidthSliderPresetTests {
    @Test("预设不含自定义,标准档下标正确")
    func presetsExcludeCustom() {
        #expect(!ChatWidth.presets.contains(.custom))
        #expect(ChatWidth.presets[ChatWidth.presetIndex(raw: "standard", custom: 900)] == .standard)
        #expect(SettingsContentWidth.presets[SettingsContentWidth.presetIndex(raw: "wide", custom: 900)] == .wide)
    }

    @Test("自定义宽度吸附到点数最近的预设,未知值回退标准")
    func customSnapsToNearest() {
        // 830pt 最接近 standard(820)
        #expect(ChatWidth.presets[ChatWidth.presetIndex(raw: "custom", custom: 830)] == .standard)
        // 1180pt 最接近 ultra(1200)
        #expect(ChatWidth.presets[ChatWidth.presetIndex(raw: "custom", custom: 1180)] == .ultra)
        #expect(SettingsContentWidth.presets[SettingsContentWidth.presetIndex(raw: "乱写", custom: 900)] == .standard)
    }

    @Test("自动压缩窗口:夹到范围并生成环境变量")
    func autoCompactWindowEnv() {
        var options = SessionOptions()
        #expect(options.effectiveAutoCompactWindow == nil)
        #expect(options.environment[SessionOptions.autoCompactKey] == nil)
        options.autoCompactWindow = 1_000
        #expect(options.environment[SessionOptions.autoCompactKey] == "50000")
        options.autoCompactWindow = 200_000
        #expect(options.environment[SessionOptions.autoCompactKey] == "200000")
        options.autoCompactWindow = 9_000_000
        #expect(options.environment[SessionOptions.autoCompactKey] == "1000000")
    }

    @Test("自动压缩窗口超过 20 万时同时声明模型窗口,否则会被夹回 20 万")
    func autoCompactWindowRaisesModelWindow() {
        var options = SessionOptions()
        options.autoCompactWindow = 200_000
        #expect(options.environment[SessionOptions.maxContextKey] == nil)
        options.autoCompactWindow = 400_000
        #expect(options.environment[SessionOptions.maxContextKey] == "400000")
        // 映射已声明模型窗口时,全局值不再覆盖它
        let mapped: JSONValue = .object(["claudeCode": .object(["options": .object(["settings": .object(["env": .object([
            SessionOptions.autoCompactKey: .string("1000000"), SessionOptions.maxContextKey: .string("1000000")])])])])])
        let merged = options.merged(into: mapped)
        #expect(merged?["claudeCode"]?["options"]?["settings"]?["env"]?[SessionOptions.maxContextKey]?.stringValue == "1000000")
        #expect(merged?["claudeCode"]?["options"]?["env"]?[SessionOptions.maxContextKey] == nil)
    }

    @Test("自动压缩窗口:与模型映射的窗口取较小值")
    func autoCompactWindowTakesSmaller() {
        let mapped: JSONValue = .object(["claudeCode": .object(["options": .object(["settings": .object(["env": .object([SessionOptions.autoCompactKey: .string("1000000")])])])])])
        var options = SessionOptions()
        options.autoCompactWindow = 200_000
        let merged = options.merged(into: mapped)
        let settingsEnv = merged?["claudeCode"]?["options"]?["settings"]?["env"]
        #expect(settingsEnv?[SessionOptions.autoCompactKey]?.stringValue == "200000")
        #expect(merged?["claudeCode"]?["options"]?["env"]?[SessionOptions.autoCompactKey] == nil)
        // 映射的窗口更小时保持映射的值
        options.autoCompactWindow = 500_000
        let kept = options.merged(into: .object(["claudeCode": .object(["options": .object(["settings": .object(["env": .object([SessionOptions.autoCompactKey: .string("128000")])])])])]))
        #expect(kept?["claudeCode"]?["options"]?["settings"]?["env"]?[SessionOptions.autoCompactKey]?.stringValue == "128000")
    }

    @Test("纯文字会话:替换系统提示、去掉工具与设置来源,并保留提供商变量")
    func plainChatMeta() {
        let mapped: JSONValue = .object(["claudeCode": .object(["options": .object(["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("tok")])])])])
        let meta = SessionOptions.plainChat(mapped, systemPrompt: "只聊天", settingsEnv: ["ANTHROPIC_AUTH_TOKEN": "other", "ANTHROPIC_BASE_URL": "https://gw.example"])
        #expect(meta["systemPrompt"]?.stringValue == "只聊天")
        let options = meta["claudeCode"]?["options"]
        #expect(options?["tools"] == .array([.string("WebSearch"), .string("WebFetch")]))
        #expect(options?["allowedTools"] == options?["tools"])
        #expect(options?["settingSources"] == .array([]))
        #expect(options?["strictMcpConfig"] == .bool(true))
        #expect(options?["extraArgs"]?["disable-slash-commands"] == JSONValue.null)
        let env = options?["env"]
        #expect(env?["ANTHROPIC_AUTH_TOKEN"]?.stringValue == "tok")
        #expect(env?["ANTHROPIC_BASE_URL"]?.stringValue == "https://gw.example")
        #expect(env?["CLAUDE_CODE_DISABLE_CLAUDE_MDS"]?.stringValue == "1")
        #expect(env?["CLAUDE_CODE_DISABLE_AUTO_MEMORY"]?.stringValue == "1")
        // 没有基础 _meta 时也能生成
        #expect(SessionOptions.plainChat(nil, systemPrompt: "x", settingsEnv: [:])["systemPrompt"]?.stringValue == "x")
    }
}
