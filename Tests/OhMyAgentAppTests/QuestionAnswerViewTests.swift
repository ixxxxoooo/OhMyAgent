// @author ixxxxoooo
// 问答摘要卡渲染测试:回答、跳过两种状态都能渲染出有高度的内容,
// 提问工具行带结果快照时可展开(有详情)。

import ACPKit
import AppKit
import ChatKit
import SwiftUI
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("提问问答卡")
struct QuestionAnswerViewTests {
    private func fittingHeight(_ outcome: ElicitationOutcome) -> CGFloat {
        let host = NSHostingView(rootView: QuestionAnswerView(outcome: outcome).frame(width: 520))
        return host.fittingSize.height
    }

    @Test("回答与跳过都能渲染;已回答的卡片比跳过的更高")
    func rendersStates() {
        let items = [
            AnsweredQuestion(id: "q0", header: "形式", prompt: "你希望以什么形式呈现?", answers: ["Mermaid 图"]),
            AnsweredQuestion(id: "q1", header: "附加", prompt: "还要什么?", answers: ["测试", "文档"], isMulti: true),
        ]
        let answered = fittingHeight(ElicitationOutcome(state: .answered, items: items))
        let skipped = fittingHeight(ElicitationOutcome(state: .skipped, items: items.map { AnsweredQuestion(id: $0.id, header: $0.header, prompt: $0.prompt) }))
        #expect(skipped > 40)
        #expect(answered > skipped)
    }

    @Test("提问工具行摘要:显示「向你提问」与题数")
    func presentation() {
        let input: JSONValue = ["questions": [["question": "a?", "options": []], ["question": "b?", "options": []]]]
        let tool = ToolCall(toolCallId: "t", name: "AskUserQuestion", title: "Asking for your input", status: .completed, rawInput: input)
        let presentation = ToolPresentation(tool: tool)
        #expect(presentation.verb == String(localized: "向你提问"))
        #expect(presentation.subject == String(localized: "2 个问题"))
    }
}
