// @author ixxxxoooo
// M6 测试:权限规则、权限存储、用量统计、设置模型。全部使用临时目录。

import Foundation
import Testing
@testable import ClaudeConfigKit

@Suite("权限规则")
struct PermissionRuleTests {
    @Test("解析与校验")
    func parseAndValidate() {
        #expect(PermissionRule("Bash(npm run test:*)")?.specifier == "npm run test:*")
        #expect(PermissionRule("WebFetch")?.specifier == nil)
        #expect(PermissionRule("Bash(npm") == nil)
        #expect(PermissionRule.validate("") != nil)
        #expect(PermissionRule.validate("Bash()") != nil)
        #expect(PermissionRule.validate("Bash(a:*b)") != nil)
        #expect(PermissionRule.validate("Read(./.env)") == nil)
    }

    @Test("匹配:前缀通配、glob、MCP 服务器级")
    func matching() {
        let prefix = PermissionRule("Bash(git commit:*)")!
        #expect(prefix.matches(tool: "Bash", argument: "git commit -m x"))
        #expect(prefix.matches(tool: "Bash", argument: "git commit"))
        #expect(!prefix.matches(tool: "Bash", argument: "git commitx"))
        #expect(!prefix.matches(tool: "Read", argument: "git commit"))
        let glob = PermissionRule("Read(./secrets/**)")!
        #expect(glob.matches(tool: "Read", argument: "./secrets/a/b.txt"))
        #expect(!glob.matches(tool: "Read", argument: "./public/a.txt"))
        #expect(!glob.matches(tool: "Read", argument: nil))
        let mcp = PermissionRule("mcp__github")!
        #expect(mcp.matches(tool: "mcp__github__create_issue", argument: nil))
        #expect(!mcp.matches(tool: "mcp__githubx__create", argument: nil))
    }
}

@Suite("权限存储")
struct PermissionsStoreTests {
    @Test("写入去重、拒绝非法规则、deny 优先")
    func storeAndEvaluate() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let store = PermissionsStore(paths: box.paths)
        try store.setRules(["Bash(npm:*)", "Bash(npm:*)", "Read"], .allow, in: .user)
        #expect(store.rules(.allow, in: .user) == ["Bash(npm:*)", "Read"])
        #expect(throws: (any Error).self) { try store.setRules(["Bash(oops"], .allow, in: .user) }
        try store.setRules(["Bash(npm publish:*)"], .deny, in: .project)
        let denied = store.evaluate(tool: "Bash", argument: "npm publish --tag x")
        #expect(denied?.behavior == .deny)
        #expect(denied?.scope == .project)
        #expect(store.evaluate(tool: "Bash", argument: "npm test")?.behavior == .allow)
        #expect(store.evaluate(tool: "Write", argument: "a.txt") == nil)
        try store.setRules([], .allow, in: .user)
        #expect(store.rules(.allow, in: .user).isEmpty)
    }
}

@Suite("用量统计")
struct UsageStatsTests {
    @Test("解析 stats-cache.json 并按日期汇总")
    func loadStats() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.write("""
        {"lastComputedDate":"2026-10-15","dailyActivity":[
          {"date":"2026-10-14","messageCount":10,"sessionCount":1,"toolCallCount":3},
          {"date":"2026-10-13","messageCount":5,"sessionCount":2,"toolCallCount":1}],
         "modelUsage":{"a":{"inputTokens":1,"outputTokens":5},"b":{"inputTokens":2,"outputTokens":9,"costUSD":1.5}}}
        """, to: ".claude/stats-cache.json", base: box.home)
        let stats = UsageStats.load(paths: box.paths)
        #expect(stats.daily.map(\.date) == ["2026-10-13", "2026-10-14"])
        #expect(stats.recent(days: 1).messages == 10)
        #expect(stats.recent(days: 7).sessions == 3)
        #expect(stats.models.first?.model == "b")
        #expect(stats.models.first?.costUSD == 1.5)
    }

    @Test("文件缺失或损坏时返回空快照")
    func missingOrCorrupt() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        #expect(UsageStats.load(paths: box.paths) == .empty)
        try box.write("{not json", to: ".claude/stats-cache.json", base: box.home)
        #expect(UsageStats.load(paths: box.paths) == .empty)
    }
}

@Suite("设置模型")
@MainActor
struct SettingsModelTests {
    @Test("按层写入、revision 递增、未知字段保留")
    func writeThroughScopes() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.write(#"{"custom":{"keep":true}}"#, to: ".claude/settings.json", base: box.home)
        let model = ClaudeSettingsModel(paths: box.paths)
        let before = model.revision
        model.set(["model"], "opus")
        #expect(model.revision > before)
        #expect(model.string(["model"]) == "opus")
        model.scope = .project
        #expect(model.string(["model"]) == nil)
        #expect(model.effective(["model"])?.scope == .user)
        model.set(["env"], ["A": "1"])
        #expect(model.dictionary(["env"]) == ["A": "1"])
        let user = try JSONFile(box.paths.userSettings).read()
        #expect((user["custom"] as? [String: Any])?["keep"] as? Bool == true)
        model.set(["env"], nil)
        #expect(model.dictionary(["env"]).isEmpty)
    }
}
