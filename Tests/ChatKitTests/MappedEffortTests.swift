// @author ixxxxoooo
// 映射会话的思考强度:网关别名按真实模型继承强度(用户按模型设置 > 内置默认 medium),第三方模型不干预。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@Suite("映射别名的思考强度")
struct MappedEffortTests {
    static let relay = ModelProvider(id: "relay", name: "Relay", baseURL: "https://relay.example.com", model: "claude-sonnet-5-5")

    /// 主槽位 Sonnet、Opus 槽位 Opus、Haiku 槽位第三方模型的映射。
    static func mapping(_ prefs: ClaudeEffortPrefs) -> ResolvedMapping {
        var mapping = ModelProviderTests.mapping(relay, "claude-sonnet-5-5")
        mapping.others[.opus] = ModelProviderTests.target(relay, "claude-opus-5-5", .opus)
        mapping.others[.haiku] = ModelProviderTests.target(relay, "deepseek-v4.1-flash", .haiku)
        mapping.effortPrefs = prefs
        return mapping
    }

    /// 取会话 settings 里某别名的强度。
    static func effort(_ meta: JSONValue, alias: String) -> String? {
        meta["claudeCode"]?["options"]?["settings"]?["modelSettings"]?[alias]?["effortLevel"]?.stringValue
    }

    @Test("用户按模型的设置优先,键大小写不敏感;未设置的 Claude 模型取内置默认 medium")
    func userSettingsThenDefault() throws {
        let prefs = ClaudeEffortPrefs(modelSettings: ["Claude-Opus-5-5": ["effortLevel": "high"]])
        let meta = ProviderLaunch.sessionMeta(Self.mapping(prefs), gateway: try #require(URL(string: "http://127.0.0.1:9/t")))
        #expect(Self.effort(meta, alias: ModelSlot.opus.alias) == "high")
        #expect(Self.effort(meta, alias: ModelSlot.main.alias) == "medium")
        // 第三方模型不干预,沿用 Claude Code 默认
        #expect(Self.effort(meta, alias: ModelSlot.haiku.alias) == nil)
        // 用户原有条目原样带上
        #expect(Self.effort(meta, alias: "Claude-Opus-5-5") == "high")
    }

    @Test("用户设置了全局强度时不套用内置默认,避免盖过全局选择")
    func globalEffortSuppressesDefault() {
        let prefs = ClaudeEffortPrefs(modelSettings: [:], globalEffort: "low")
        #expect(prefs.effort(forModel: "claude-sonnet-5-5") == nil)
        #expect(MappedEffort.modelSettings(Self.mapping(prefs), prefs: prefs) == nil)
    }

    @Test("Fable 与第三方模型无内置默认;空模型 ID 返回 nil")
    func unknownFamilies() {
        let prefs = ClaudeEffortPrefs()
        #expect(prefs.effort(forModel: "claude-fable-5-1") == nil)
        #expect(prefs.effort(forModel: "gpt-6-astra") == nil)
        #expect(prefs.effort(forModel: " ") == nil)
        #expect(prefs.effort(forModel: "claude-haiku-5-5") == "medium")
    }

    @Test("从 settings.json 读取按模型设置与全局强度;文件缺失返回空偏好")
    func loadFromDisk() throws {
        let home = try ModelProviderTests.tempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ClaudeEffortPrefs.load(home: home) == ClaudeEffortPrefs())
        let dir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"effortLevel":"xhigh","modelSettings":{"claude-sonnet-5-5":{"effortLevel":"low"}}}"#
        try json.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let prefs = ClaudeEffortPrefs.load(home: home)
        #expect(prefs.globalEffort == "xhigh")
        #expect(prefs.effort(forModel: "claude-sonnet-5-5") == "low")
        #expect(prefs.effort(forModel: "claude-opus-5-5") == nil)
    }
}
