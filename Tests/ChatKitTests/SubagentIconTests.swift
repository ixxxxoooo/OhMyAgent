// @author ixxxxoooo
// 子代理类型图标映射。

import Testing
@testable import ChatKit

@Suite("子代理图标")
struct SubagentIconTests {
    @Test("常见类型映射到各自图标,未知与空回退通用图标")
    func mapping() {
        #expect(SubagentIcon.symbol(for: "Explore") == "file-search")
        #expect(SubagentIcon.symbol(for: "code-reviewer") == "shield-check")
        #expect(SubagentIcon.symbol(for: "Plan") == "workflow")
        #expect(SubagentIcon.symbol(for: "general-purpose") == "bot")
        #expect(SubagentIcon.symbol(for: nil) == "bot")
        #expect(SubagentIcon.symbol(for: "") == "bot")
    }
}
