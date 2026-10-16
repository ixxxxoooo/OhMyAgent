// @author ixxxxoooo
// Agent 预设测试:Pi 预设通过 npx 运行 pi-acp,且预设 ID 唯一、可转为描述符。

import Foundation
import Testing
@testable import OhMyAgentApp

@Suite("Agent 预设")
struct AgentPresetTests {
    @Test("包含 Pi 预设:npx 运行并固定 pi-acp 版本")
    func piPreset() throws {
        let preset = try #require(AgentPreset.all.first { $0.id == "pi" })
        #expect(preset.command == "npx")
        #expect(preset.args == ["-y", "pi-acp@\(AgentPreset.piAcpVersion)"])
    }

    @Test("本机已全局安装 pi-acp 时,Pi 预设直接使用它而不走 npx")
    func piPrefersGlobalInstall() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oma-pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("pi-acp")
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let preset = try #require(AgentPreset.all.first { $0.id == "pi" })
        let draft = AgentDraft(preset, path: dir.path)
        #expect(draft.command == "pi-acp")
        #expect(draft.args.isEmpty)
    }

    @Test("预设 ID 唯一")
    func uniqueIDs() {
        let ids = AgentPreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Pi 预设转为描述符:参数按空白拆分且默认启用")
    func piDescriptor() throws {
        let preset = try #require(AgentPreset.all.first { $0.id == "pi" })
        let descriptor = AgentDraft(preset, path: "").descriptor(enabled: true)
        #expect(descriptor.id == "pi")
        #expect(descriptor.command == "npx")
        #expect(descriptor.args == ["-y", "pi-acp@\(AgentPreset.piAcpVersion)"])
        #expect(descriptor.enabled)
    }
}
