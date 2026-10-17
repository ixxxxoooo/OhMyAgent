// @author ixxxxoooo
// 设置页路由测试:扩展拆分后的页面、旧名称兼容、分组完整性与搜索关键词。

import Testing
@testable import OhMyAgentApp

@Suite("设置页路由")
struct SettingsPageTests {
    @Test("旧的 tools 页名映射到 MCP 页")
    func legacyToolsMapsToMCP() {
        #expect(SettingsPage.resolve("tools") == .mcp)
        #expect(SettingsPage.resolve("skills") == .skills)
        #expect(SettingsPage.resolve("不存在") == nil)
    }

    @Test("扩展分区各自对应独立设置页")
    func extensionSectionPages() {
        #expect(ExtensionSection.mcp.page == .mcp)
        #expect(ExtensionSection.skills.page == .skills)
        #expect(ExtensionSection.agents.page == .subagents)
        #expect(ExtensionSection.hooks.page == .hooks)
        #expect(ExtensionSection.plugins.page == .plugins)
        #expect(ExtensionSection.memory.page == .memory)
    }

    @Test("除已并入「自定义」页的扩展页外,设置页都出现在侧栏分组里且不重复")
    func groupsCoverAllPages() {
        let listed = SettingsPage.groups.flatMap(\.pages)
        #expect(Set(listed).count == listed.count)
        let movedToCustomize = SettingsPage.allCases.filter { CustomizeFilter.from(page: $0) != nil }
        #expect(Set(listed).isDisjoint(with: movedToCustomize))
        #expect(Set(listed) == Set(SettingsPage.allCases).subtracting(movedToCustomize))
    }

    @Test("搜索关键词能命中扩展页")
    func keywordsMatch() {
        #expect(SettingsPage.mcp.keywords.contains("mcp"))
        #expect(SettingsPage.skills.keywords.contains("技能"))
        #expect(SettingsPage.agentExtensions.keywords.contains("pi"))
    }
}
