// @author ixxxxoooo
// 演示启动钩子测试:OMA_DEMO_OPEN_SESSIONS 的解析。

import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("演示启动钩子")
struct DemoLaunchHooksTests {
    @Test("解析 项目:序号 列表,忽略空白与非法项")
    func parse() {
        let list = DemoLaunchHooks.parseOpenSessions("perf-longchat:1, perf-render:2 ,bad,perf-x:0,:3,perf-y:abc")
        #expect(list.map(\.project) == ["perf-longchat", "perf-render"])
        #expect(list.map(\.index) == [1, 2])
        #expect(DemoLaunchHooks.parseOpenSessions(nil).isEmpty)
        #expect(DemoLaunchHooks.parseOpenSessions("").isEmpty)
    }
}
