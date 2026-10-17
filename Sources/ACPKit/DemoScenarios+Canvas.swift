// @author ixxxxoooo
// 演示场景:Agent 通过 Bridge 创建画布(canvas_create)与更新画布(canvas_update),时间线里出现「画布卡片」。
// 画布文档由 DemoKit 预置在沙盒(固定标识 `demo-quarterly-report`),这里只模拟工具调用与结果。

import Foundation

extension DemoScenarios {
    /// 画布:创建 + 更新。
    static func canvasTools(_ c: ScenarioContext) -> [ScenarioStep] {
        let created = "Canvas created. canvas_id: demo-quarterly-report\ntitle: Atlas 第三季度质量周报\nblocks: 14, revision: 1\nThe user can see it in the OhMyAgent Canvas tab. To change it, call canvas_update with this canvas_id."
        let updated = "Canvas updated. canvas_id: demo-quarterly-report\ntitle: Atlas 第三季度质量周报\nblocks: 14, revision: 2\nThe user can see it in the OhMyAgent Canvas tab. To change it, call canvas_update with this canvas_id."
        return DemoSteps.withUsage([
            DemoSteps.say("数据比较多,我整理成一个画布,方便你对照图表和表格。\n\n"),
            .tool(ScenarioTool(id: "cv_create", title: "mcp__ohmyagent__canvas_create", kind: "other", name: "mcp__ohmyagent__canvas_create",
                               input: ["title": "Atlas 第三季度质量周报",
                                       "blocks": [["type": "heading", "text": "Atlas 第三季度质量周报", "level": 1],
                                                  ["type": "stats", "items": [["label": "合并 PR", "value": "42", "delta": "+8"]]]]],
                               output: created)),
            DemoSteps.say("已创建。再补充一条风险提示:\n\n"),
            .tool(ScenarioTool(id: "cv_update", title: "mcp__ohmyagent__canvas_update", kind: "other", name: "mcp__ohmyagent__canvas_update",
                               input: ["id": "demo-quarterly-report",
                                       "append_blocks": [["type": "callout", "tone": "warning", "title": "风险", "text": "Metrics 覆盖率低于目标。"]]],
                               output: updated)),
            DemoSteps.say("点击上方卡片即可在标签页里查看,支持切换源码、导出 PNG。\n"),
        ], used: 18_400)
    }
}
