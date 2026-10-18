// @author ixxxxoooo
// 自定义页测试:设置页深链映射、筛选解析。

import Testing

@testable import OhMyAgentApp

@Suite("自定义页")
struct CustomizePageTests {
    /// 扩展类设置页都能映射到筛选,其它页面不映射。
    @Test("设置页深链映射")
    func pageMapping() {
        #expect(CustomizeFilter.from(page: .mcp) == .mcp)
        #expect(CustomizeFilter.from(page: .memory) == .rules)
        #expect(CustomizeFilter.from(page: .subagents) == .subagents)
        #expect(CustomizeFilter.from(page: .general) == nil)
    }

    /// 无法识别的存储值回退为「插件」。
    @Test("筛选解析回退")
    func resolveFallback() {
        #expect(CustomizeFilter.resolve("mcp") == .mcp)
        #expect(CustomizeFilter.resolve("不存在") == .plugins)
    }
}
