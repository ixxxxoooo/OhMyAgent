// @author ixxxxoooo
// Agent 预设测试:Pi 预设通过 npx 运行 pi-acp,且预设 ID 唯一、可转为描述符。

import Testing
@testable import OhMyAgentApp

@Suite("Agent 预设")
struct AgentPresetTests {
    @Test("包含 Pi 预设:npx -y pi-acp")
    func piPreset() throws {
        let preset = try #require(AgentPreset.all.first { $0.id == "pi" })
        #expect(preset.command == "npx")
        #expect(preset.args == ["-y", "pi-acp"])
    }

    @Test("预设 ID 唯一")
    func uniqueIDs() {
        let ids = AgentPreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Pi 预设转为描述符:参数按空白拆分且默认启用")
    func piDescriptor() throws {
        let preset = try #require(AgentPreset.all.first { $0.id == "pi" })
        let descriptor = AgentDraft(preset).descriptor(enabled: true)
        #expect(descriptor.id == "pi")
        #expect(descriptor.command == "npx")
        #expect(descriptor.args == ["-y", "pi-acp"])
        #expect(descriptor.enabled)
    }
}
