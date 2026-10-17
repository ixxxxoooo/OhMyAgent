// @author ixxxxoooo
// 自定义页测试:设置页深链映射、筛选解析、条目归并(需要处理 / 已停用分组)。

import ClaudeConfigKit
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

    /// 无法识别的存储值回退为「全部」。
    @Test("筛选解析回退")
    func resolveFallback() {
        #expect(CustomizeFilter.resolve("mcp") == .mcp)
        #expect(CustomizeFilter.resolve("不存在") == .all)
    }

    /// MCP 待批准/失败进入「需要处理」,停用的单独标记,其余视为已连接。
    @Test("MCP 状态归并")
    func mcpStatuses() {
        var snapshot = ConfigSnapshot()
        func entry(_ name: String, disabled: Bool = false, approval: Bool = false) -> MCPServerEntry {
            MCPServerEntry(config: MCPServerConfig(name: name, command: "node"), scope: .user, overriddenBy: nil,
                           isDisabled: disabled, needsApproval: approval)
        }
        snapshot.mcp = [entry("ok"), entry("off", disabled: true), entry("wait", approval: true), entry("bad")]
        let health = ["bad": MCPHealthStatus(name: "bad", state: .failed, detail: "x")]
        let items = CustomizePage.items(from: snapshot, health: health)
        let attention = items.filter(\.needsAttention).map(\.title).sorted()
        #expect(attention == ["bad", "wait"])
        #expect(items.count == 4)
    }
}
