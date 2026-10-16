// @author ygw
// 项目信任读写:保留 ~/.claude.json 中的其它字段。

import Foundation
import Testing
@testable import ClaudeConfigKit

@Suite("项目信任")
struct ProjectTrustTests {
    @Test("未记录的项目视为未信任;设置后可读回")
    func setAndRead() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let trust = ProjectTrust(paths: sandbox.paths)
        #expect(!trust.isTrusted("/tmp/demo"))
        try trust.setTrusted(true, for: "/tmp/demo")
        #expect(trust.isTrusted("/tmp/demo"))
        #expect(trust.isTrusted("/tmp/demo/"))
        try trust.setTrusted(false, for: "/tmp/demo")
        #expect(!trust.isTrusted("/tmp/demo"))
    }

    @Test("写入保留顶层与项目内的其它字段")
    func preservesOtherFields() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        try sandbox.write(#"{"numStartups": 7, "projects": {"/tmp/demo": {"allowedTools": ["Bash"], "mcpServers": {}}}}"#, to: ".claude.json", base: sandbox.home)
        let trust = ProjectTrust(paths: sandbox.paths)
        try trust.setTrusted(true, for: "/tmp/demo")
        let root = try JSONFile(sandbox.paths.claudeJSON).read()
        #expect(root["numStartups"] as? Int == 7)
        let project = (root["projects"] as? [String: Any])?["/tmp/demo"] as? [String: Any]
        #expect(project?["allowedTools"] as? [String] == ["Bash"])
        #expect(project?["hasTrustDialogAccepted"] as? Bool == true)
    }

    @Test("批量读取与空路径校验")
    func statusesAndValidation() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let trust = ProjectTrust(paths: sandbox.paths)
        try trust.setTrusted(true, for: "/a")
        let result = trust.statuses(for: ["/a", "/b"])
        #expect(result["/a"] == true && result["/b"] == false)
        #expect(throws: ConfigError.self) { try trust.setTrusted(true, for: "") }
    }
}
