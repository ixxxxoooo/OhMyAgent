// @author ixxxxoooo
// OpenCode 计划模式的计划批准:判断回复是否像计划、取本轮最后一段回复、合成与 ExitPlanMode 同构的请求。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@MainActor
@Suite("OpenCode 计划批准")
struct OpenCodePlanTests {
    private static let plan = """
    ## 优化计划(按风险从低到高)

    ### P0 建立安全网
    1. 新增 pyproject.toml:ruff、pytest,固定依赖版本。
    2. 为 common.py 里的纯函数补单测。
    3. 新增 AGENTS.md:约定跑测、校验命令。

    ### P1 拆公共层
    4. 把 common.py 拆成包 qianyi/,按请求、报告、下线过滤分模块。
    5. script/*.py 保留为薄壳,保证 README 里所有命令不变。

    要我从 P0 开始吗?
    """

    private func entry(_ kind: TimelineEntry.Kind, _ text: String = "") -> TimelineEntry {
        TimelineEntry(kind: kind, text: text)
    }

    @Test("有标题与列表的长回复像计划;短回复、无结构的长回复不像")
    func looksLikePlan() {
        #expect(OpenCodePlan.looksLikePlan(Self.plan))
        #expect(!OpenCodePlan.looksLikePlan("我是 opencode,一个帮助你处理软件工程任务的命令行 AI 助手。"))
        #expect(!OpenCodePlan.looksLikePlan(String(repeating: "这是一段没有任何结构的很长的叙述。", count: 30)))
    }

    @Test("取最后一条用户消息之后的最后一段助手回复")
    func lastAssistantText() {
        let entries = [entry(.user, "旧问题"), entry(.assistant, "旧回复"), entry(.user, "新问题"),
                       entry(.assistant, "过程说明"), entry(.tool), entry(.assistant, Self.plan), entry(.turnSummary)]
        #expect(OpenCodePlan.lastAssistantText(in: entries) == Self.plan.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(OpenCodePlan.lastAssistantText(in: [entry(.user, "问题"), entry(.tool)]) == nil)
    }

    @Test("本轮已有计划卡时不再重复提出")
    func noDuplicate() {
        let entries = [entry(.user, "问题"), entry(.assistant, Self.plan), entry(.planDoc, Self.plan)]
        #expect(OpenCodePlan.lastAssistantText(in: entries) == nil)
    }

    @Test("合成请求与 ExitPlanMode 同构:计划在 rawInput.plan,两个选项")
    func request() throws {
        let request = try #require(OpenCodePlan.request(sessionId: "s1", plan: "计划正文"))
        let call = ToolCall(json: request.toolCallRaw)
        #expect(call.name == "ExitPlanMode")
        #expect(call.rawInput?["plan"]?.stringValue == "计划正文")
        #expect(request.options.map(\.optionId) == [OpenCodePlan.buildOptionId, OpenCodePlan.keepOptionId])
        #expect(request.options.first?.kind == .allowOnce)
        #expect(request.options.last?.kind == .rejectOnce)
    }
}
