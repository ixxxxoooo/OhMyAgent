// @author ixxxxoooo
// 工具审批策略测试:三档、命令/来源匹配、串联命令不放行、偏好读写与权限请求解析。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@Suite("工具审批策略")
struct ToolApprovalTests {
    @Test("每次询问与自动运行")
    func modes() {
        #expect(ToolApprovalPolicy(mode: .ask, allowlist: ["ls"]).decide(subject: "ls", domain: .terminal) == .ask)
        #expect(ToolApprovalPolicy(mode: .auto).decide(subject: "rm -rf x", domain: .terminal) == .allow)
    }

    @Test("允许列表:精确、空格前缀与通配")
    func commandMatching() {
        let policy = ToolApprovalPolicy(mode: .allowlist, allowlist: ["git status", "npm run *"])
        #expect(policy.decide(subject: "git status", domain: .terminal) == .allow)
        #expect(policy.decide(subject: "git   status  -s", domain: .terminal) == .allow)
        #expect(policy.decide(subject: "git statusx", domain: .terminal) == .ask)
        #expect(policy.decide(subject: "git push", domain: .terminal) == .ask)
        #expect(policy.decide(subject: "npm run test", domain: .terminal) == .allow)
        #expect(policy.decide(subject: "npm install", domain: .terminal) == .ask)
    }

    @Test("串联、重定向与命令替换不凭前缀放行")
    func compoundCommands() {
        let policy = ToolApprovalPolicy(mode: .allowlist, allowlist: ["git status", "ls *"])
        for command in ["git status; rm -rf ~", "git status && curl x", "git status | sh", "ls > /etc/hosts", "ls $(whoami)", "ls `id`", "git status\nrm x"] {
            #expect(policy.decide(subject: command, domain: .terminal) == .ask, "应询问:\(command)")
        }
    }

    @Test("浏览器来源匹配:主机、通配子域、带协议")
    func originMatching() {
        let policy = ToolApprovalPolicy(mode: .allowlist, allowlist: ["localhost", "*.example.com", "https://docs.dev"])
        #expect(policy.decide(subject: "http://localhost:3000/a", domain: .browser) == .allow)
        #expect(policy.decide(subject: "https://api.example.com/x", domain: .browser) == .allow)
        #expect(policy.decide(subject: "https://example.com", domain: .browser) == .allow)
        #expect(policy.decide(subject: "https://evilexample.com", domain: .browser) == .ask)
        #expect(policy.decide(subject: "https://docs.dev/guide", domain: .browser) == .allow)
        #expect(policy.decide(subject: "http://docs.dev/guide", domain: .browser) == .ask)
        #expect(policy.decide(subject: "not a url", domain: .browser) == .ask)
    }

    @Test("偏好读写与列表解析去重")
    func persistence() {
        let suite = "oma-approval-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ToolApprovalPolicy.load(.terminal, defaults) == ToolApprovalPolicy())
        defaults.set("allowlist", forKey: ToolApprovalDomain.terminal.modeKey)
        ToolApprovalPolicy.saveList(["ls", " ls ", "", "pwd"], for: .terminal, defaults)
        let loaded = ToolApprovalPolicy.load(.terminal, defaults)
        #expect(loaded.mode == .allowlist)
        #expect(loaded.allowlist == ["ls", "pwd"])
        #expect(ToolApprovalPolicy.load(.browser, defaults).mode == .ask)
    }

    @Test("从权限请求里识别终端命令与浏览器 URL")
    func subjectOfCall() {
        let shell = ToolCall(toolCallId: "1", name: "Bash", title: "Run", kind: .execute, rawInput: ["command": "ls -la"])
        #expect(ToolApprovalPolicy.subject(of: shell)?.domain == .terminal)
        #expect(ToolApprovalPolicy.subject(of: shell)?.subject == "ls -la")
        let nav = ToolCall(toolCallId: "2", name: "mcp__ohmyagent__browser_navigate", kind: .other, rawInput: ["url": "https://a.com"])
        #expect(ToolApprovalPolicy.subject(of: nav)?.domain == .browser)
        #expect(ToolApprovalPolicy.subject(of: ToolCall(toolCallId: "3", name: "Read", kind: .read)) == nil)
    }
}
