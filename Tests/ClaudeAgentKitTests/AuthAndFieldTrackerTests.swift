// @author ixxxxoooo
// 鉴权身份映射与工具调用字段去重的单元测试(不依赖真实 claude 与网络)。

import ACPKit
import Foundation
import Testing
@testable import ClaudeAgentKit

@Suite("鉴权身份映射")
struct AuthStatusTests {
    @Test("订阅账号映射为 Claude 套餐标签并带账号信息")
    func subscriptionAccount() throws {
        let status = try #require(AuthStatus.from(cliOutput: #"{"loggedIn":true,"subscriptionType":"max","email":"a@b.c","orgName":"Org"}"#))
        #expect(status.kind == "account")
        #expect(status.label == "Claude Max")
        #expect(status.account?.email == "a@b.c")
        #expect(status.account?.organization == "Org")
    }

    @Test("API Key 与外部云凭据")
    func apiKeyAndExternal() throws {
        let key = try #require(AuthStatus.from(cliOutput: #"{"loggedIn":true,"apiKeySource":"ANTHROPIC_API_KEY"}"#))
        #expect(key.kind == "api_key")
        #expect(key.detail == "ANTHROPIC_API_KEY")
        let cloud = try #require(AuthStatus.from(cliOutput: #"{"loggedIn":true,"apiProvider":"bedrock"}"#))
        #expect(cloud.kind == "external")
        #expect(cloud.label == "AWS Bedrock")
    }

    @Test("未登录与非 JSON 输出")
    func notLoggedInAndGarbage() {
        #expect(AuthStatus.from(cliOutput: #"{"loggedIn":false}"#) == .notLoggedIn)
        #expect(AuthStatus.from(cliOutput: "not json") == nil)
        #expect(AuthStatus.from(cliOutput: #"{"foo":1}"#) == nil)
    }

    @Test("网关只上报主机名")
    func gatewayHostOnly() {
        let status = AuthStatus.gateway(baseUrl: "http://127.0.0.1:50491/route/secret-token")
        #expect(status.kind == "gateway")
        #expect(status.detail == "127.0.0.1")
        #expect(status.json["detail"]?.stringValue == "127.0.0.1")
    }

    @Test("会话 account 无身份信号时返回 nil,不会被当作已登出")
    func emptyAccountIsNoSignal() {
        #expect(AuthStatus.from(account: .object([:])) == nil)
        #expect(AuthStatus.from(account: .object(["apiProvider": "firstParty"])) == nil)
        #expect(AuthStatus.from(account: .object(["subscriptionType": "pro"]))?.label == "Claude Pro")
    }

    @Test("同一登录合并缺失字段,不同登录整体替换")
    func mergeSemantics() throws {
        let previous = try #require(AuthStatus.from(cliOutput: #"{"loggedIn":true,"subscriptionType":"pro","email":"a@b.c","orgName":"Org"}"#))
        let sameLogin = AuthStatus(kind: "account", label: "Claude Pro", account: .init(plan: "pro", email: "a@b.c", organization: nil))
        #expect(sameLogin.merged(into: previous).account?.organization == "Org")
        let other = AuthStatus(kind: "account", label: "Claude Pro", account: .init(plan: "pro", email: "x@y.z", organization: nil))
        #expect(other.merged(into: previous).account?.organization == nil)
    }
}

@Suite("工具调用字段去重")
struct ToolCallFieldTrackerTests {
    private func update(_ fields: [String: JSONValue]) -> JSONValue {
        var object: [String: JSONValue] = ["sessionUpdate": "tool_call_update", "toolCallId": "t1"]
        for (key, value) in fields { object[key] = value }
        return .object(object)
    }

    private func call(_ fields: [String: JSONValue]) -> JSONValue {
        var object: [String: JSONValue] = ["sessionUpdate": "tool_call", "toolCallId": "t1"]
        for (key, value) in fields { object[key] = value }
        return .object(object)
    }

    @Test("未变化的字段被剔除,全部未变化时整条丢弃")
    func dropsUnchanged() {
        var tracker = ToolCallFieldTracker()
        var first = call(["title": "Write a.txt", "status": "pending", "rawInput": .object(["x": 1])])
        let r_first = tracker.apply(&first)
        #expect(r_first)
        var same = update(["title": "Write a.txt", "rawInput": .object(["x": 1])])
        let r_same = tracker.apply(&same)
        #expect(!r_same)
        var changed = update(["title": "Write a.txt", "status": "in_progress"])
        let r_changed = tracker.apply(&changed)
        #expect(r_changed)
        #expect(changed["title"] == nil)
        #expect(changed["status"]?.stringValue == "in_progress")
    }

    @Test("固定的审批补丁不被流式细化覆盖,终态结果可替换")
    func pinnedContent() {
        var tracker = ToolCallFieldTrackerTests.seeded()
        tracker.pinContent("t1", [.object(["type": "diff"])])
        var refine = update(["content": [.object(["type": "content"])]])
        _ = tracker.apply(&refine)
        #expect(refine["content"] == nil)
        var final = update(["content": [.object(["type": "content", "text": "done"])]])
        let r_final = tracker.apply(&final, replacePinnedContent: true)
        #expect(r_final)
        #expect(final["content"] != nil)
    }

    @Test("会话收尾后忘记全部调用")
    func clearForgets() {
        var tracker = ToolCallFieldTrackerTests.seeded()
        tracker.clear()
        var again = update(["title": "T"])
        let r_again = tracker.apply(&again)
        #expect(r_again)
        #expect(again["title"]?.stringValue == "T")
    }

    private static func seeded() -> ToolCallFieldTracker {
        var tracker = ToolCallFieldTracker()
        var first: JSONValue = .object(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "T", "content": []])
        _ = tracker.apply(&first)
        return tracker
    }
}
