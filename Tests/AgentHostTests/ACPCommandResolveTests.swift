// @author ixxxxoooo
// ACP 命令解析:PATH 之外的兜底目录、`opencode` → `opencode2` 别名、OpenCode 变体识别。

import Foundation
import Testing

@testable import AgentHost

@Suite("ACP 命令解析")
struct ACPCommandResolveTests {
    /// 造一个含若干可执行文件的临时目录。
    private func makeDirectory(_ names: [String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oma-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let file = dir.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return dir.path
    }

    @Test("PATH 里没有时回退到兜底目录")
    func fallbackDirectory() throws {
        let dir = try makeDirectory(["mytool"])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(GenericACPProvider.resolve("mytool", path: "/nonexistent", fallbacks: [dir]) == "\(dir)/mytool")
        #expect(GenericACPProvider.resolve("mytool", path: "/nonexistent", fallbacks: []) == nil)
    }

    @Test("opencode 不存在时使用本机常见的改名 opencode2")
    func opencode2Alias() throws {
        let dir = try makeDirectory(["opencode2"])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(GenericACPProvider.resolve("opencode", path: dir, fallbacks: []) == "\(dir)/opencode2")
        // 两者都有时优先 opencode
        let both = try makeDirectory(["opencode", "opencode2"])
        defer { try? FileManager.default.removeItem(atPath: both) }
        #expect(GenericACPProvider.resolve("opencode", path: both, fallbacks: []) == "\(both)/opencode")
    }

    @Test("绝对路径原样返回;OpenCode 变体识别")
    func absoluteAndVariants() {
        #expect(GenericACPProvider.resolve("/usr/bin/true", path: "") == "/usr/bin/true")
        #expect(GenericACPProvider.isOpenCode("/Users/x/.local/bin/opencode2"))
        #expect(GenericACPProvider.isOpenCode("opencode"))
        #expect(!GenericACPProvider.isOpenCode("opencode-cli"))
        #expect(!GenericACPProvider.isOpenCode("codex"))
    }

    @Test("opencode2 同样注入 question 禁用配置")
    func overridesForVariant() {
        var env: [String: String] = [:]
        GenericACPProvider.applyOpenCodeOverrides(&env, executable: "/Users/x/.local/bin/opencode2", arguments: ["acp"])
        #expect(env["OPENCODE_CONFIG_CONTENT"] != nil)
    }
}
