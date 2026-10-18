// @author ixxxxoooo
// 提问结果快照:AskUserQuestion 回答(或跳过/取消)后,把「问了什么、怎么答的」固化下来,
// 挂在对应的工具条目上,由 `QuestionAnswerView` 渲染(对齐 Cursor:回答后展开问答摘要)。
// 也能从历史会话里的 `tool_use.input.questions` 与 `tool_result` 文本还原。纯逻辑,无视图。

import ACPKit
import Foundation

/// 一道已提问的题目及用户的回答。
public struct AnsweredQuestion: Sendable, Equatable, Identifiable {
    public var id: String
    /// 短标题(如「形式」);没有则为 nil
    public var header: String?
    /// 题干
    public var prompt: String
    /// 用户选择的答案(选项标题,含「其他」自定义文本);未作答为空
    public var answers: [String]
    /// 是否多选
    public var isMulti: Bool

    public init(id: String, header: String? = nil, prompt: String, answers: [String] = [], isMulti: Bool = false) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.answers = answers
        self.isMulti = isMulti
    }

    /// 是否已作答。
    public var isAnswered: Bool { !answers.isEmpty }
}

/// 一次提问的结果。
public struct ElicitationOutcome: Sendable, Equatable {
    /// 结果状态。
    public enum State: Sendable, Equatable {
        /// 已提交回答
        case answered
        /// 用户跳过
        case skipped
        /// 被取消(轮次中断等)
        case cancelled
    }

    public var state: State
    public var items: [AnsweredQuestion]

    public init(state: State, items: [AnsweredQuestion]) {
        self.state = state
        self.items = items
    }

    /// 摘要标题:「已回答 2 个问题」「已跳过」「已取消」。
    public var title: String {
        switch state {
        case .answered: return String(localized: "已回答 \(items.count) 个问题")
        case .skipped: return String(localized: "已跳过提问")
        case .cancelled: return String(localized: "提问已取消")
        }
    }
}

extension ElicitationPrompt {
    /// 由当前表单状态生成结果快照;不是 AskUserQuestion 形态(通用表单、URL 模式)返回 nil。
    /// - Parameter state: 结果状态
    func makeOutcome(state: ElicitationOutcome.State) -> ElicitationOutcome? {
        guard let questions else { return nil }
        let items = questions.map { question -> AnsweredQuestion in
            var answers = options(of: question)
            let custom = question.customText
            if !custom.isEmpty { answers.append(custom) }
            return AnsweredQuestion(id: question.id, header: question.header, prompt: question.prompt,
                                    answers: state == .answered ? answers : [], isMulti: question.isMulti)
        }
        return ElicitationOutcome(state: state, items: items)
    }

    /// 题目中被选中的选项标题(按选项原始顺序)。
    private func options(of question: ElicitQuestion) -> [String] {
        question.options.filter { question.field.selection.contains($0.value) }.map(\.title)
    }
}

extension ElicitationOutcome {
    /// 是否为 AskUserQuestion 工具调用。
    /// - Parameter tool: 工具调用
    public static func isAskQuestion(_ tool: ToolCall) -> Bool {
        if tool.name == "AskUserQuestion" { return true }
        if tool.title == "Asking for your input" { return true }
        if tool.callsMcpTool(withPrefix: "ask_user_question") { return true }
        return tool.rawInput?["questions"]?.arrayValue?.contains { $0["question"]?.stringValue != nil } == true
    }

    /// 从历史工具调用还原(解析 `rawInput.questions` 与结果文本);信息不足返回 nil。
    ///
    /// Claude Code 的结果文本形如:`User has answered your questions: "问题"="答案", "问题2"="答案2". You can now continue…`
    /// - Parameter tool: 工具调用
    public static func replayed(from tool: ToolCall) -> ElicitationOutcome? {
        guard isAskQuestion(tool), let raw = tool.mcpInput?["questions"]?.arrayValue, !raw.isEmpty else { return nil }
        let pairs = parseAnswers(tool.resultText ?? "")
        let items = raw.enumerated().compactMap { index, item -> AnsweredQuestion? in
            guard let prompt = item["question"]?.stringValue else { return nil }
            let header = item["header"]?.stringValue
            let answer = pairs[prompt]
            let list = answer.map { text -> [String] in
                (item["multiSelect"]?.boolValue == true) ? text.components(separatedBy: ", ").filter { !$0.isEmpty } : [text]
            } ?? []
            return AnsweredQuestion(id: "q\(index)", header: header?.isEmpty == true ? nil : header, prompt: prompt,
                                    answers: list, isMulti: item["multiSelect"]?.boolValue == true)
        }
        guard !items.isEmpty else { return nil }
        let answered = items.contains(where: \.isAnswered)
        let state: State
        if answered { state = .answered }
        else if tool.status == .failed { state = .cancelled }
        else if tool.status == .completed { state = .skipped }
        else { return nil }
        return ElicitationOutcome(state: state, items: items)
    }

    /// 解析结果文本里的 `"问题"="答案"` 对。
    /// - Parameter text: 工具结果文本
    /// - Returns: 问题 → 答案
    static func parseAnswers(_ text: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"="((?:[^"\\]|\\.)*)""#) else { return [:] }
        let range = NSRange(text.startIndex..., in: text)
        var result: [String: String] = [:]
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            result[unescape(String(text[keyRange]))] = unescape(String(text[valueRange]))
        }
        return result
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
