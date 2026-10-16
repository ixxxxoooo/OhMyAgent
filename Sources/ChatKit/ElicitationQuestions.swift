// @author ygw
// AskUserQuestion 的「问卷」视图模型:把适配器下发的 `question_<n>` / `question_<n>_custom` 字段
// 归并成逐题步骤(向导),并提供选择/自定义输入的互斥规则(对齐 kuku 的问答面板)。
// 纯逻辑,无视图;非问卷形态的表单(MCP 任意表单)返回 nil,由通用表单渲染。

import Foundation

/// 向导中的一道题。
@MainActor
public struct ElicitQuestion: Identifiable {
    /// 题目对应的选择字段(`question_<n>`)。
    public let field: ElicitField
    /// 「其他」自定义输入字段(`question_<n>_custom`),可能不存在。
    public let custom: ElicitField?
    /// 短标题(Claude 的 `header`,如「方案」);缺省为 nil。
    public let header: String?
    /// 题干文本。
    public let prompt: String
    /// 选项。
    public let options: [ElicitOption]
    /// 是否多选。
    public let isMulti: Bool

    public nonisolated let id: String

    init(field: ElicitField, custom: ElicitField?, header: String?, prompt: String, options: [ElicitOption], isMulti: Bool) {
        self.id = field.id
        self.field = field
        self.custom = custom
        self.header = header
        self.prompt = prompt
        self.options = options
        self.isMulti = isMulti
    }

    /// 自定义输入的有效文本(去首尾空白)。
    public var customText: String {
        (custom?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否已作答:选了选项,或填写了自定义内容。
    public var isAnswered: Bool { !field.selection.isEmpty || !customText.isEmpty }

    /// 点选一个选项。单选:选中即清空自定义输入(互斥);多选:切换选中。
    /// - Parameter value: 选项取值
    public func choose(_ value: String) {
        guard options.contains(where: { $0.value == value }) else { return }
        if isMulti {
            if field.selection.contains(value) { field.selection.remove(value) } else { field.selection.insert(value) }
        } else {
            field.selection = [value]
            custom?.text = ""
        }
    }

    /// 修改自定义输入。单选题输入内容时清除已选选项(互斥)。
    /// - Parameter text: 新文本
    public func setCustomText(_ text: String) {
        guard let custom else { return }
        custom.text = text
        if !isMulti, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            field.selection = []
        }
    }
}

extension ElicitationPrompt {
    /// 问卷形态的逐题步骤;不是 AskUserQuestion 形态(含 URL 模式、字段类型不符)时返回 nil。
    public var questions: [ElicitQuestion]? {
        guard case .form = mode, !fields.isEmpty else { return nil }
        var customs: [String: ElicitField] = [:]
        var mains: [ElicitField] = []
        for field in fields {
            if let base = Self.customBase(of: field.id) {
                guard case .text = field.kind else { return nil }
                customs[base] = field
            } else if Self.isQuestionID(field.id) {
                mains.append(field)
            } else {
                return nil
            }
        }
        guard !mains.isEmpty else { return nil }
        let single = mains.count == 1
        var result: [ElicitQuestion] = []
        for field in mains {
            let options: [ElicitOption]
            let isMulti: Bool
            switch field.kind {
            case .single(let list): options = list; isMulti = false
            case .multi(let list): options = list; isMulti = true
            default: return nil
            }
            guard !options.isEmpty else { return nil }
            // 标题缺省时解析器会回填字段 id,此时没有短标题
            let header = (field.title.isEmpty || field.title == field.id) ? nil : field.title
            // 单题时题干在 message;多题时在字段描述里
            let text = single ? message : (field.detail ?? message)
            result.append(ElicitQuestion(field: field, custom: customs[field.id], header: header,
                                         prompt: text, options: options, isMulti: isMulti))
        }
        return result
    }

    /// 是否形如 `question_<数字>`。
    nonisolated static func isQuestionID(_ id: String) -> Bool {
        guard id.hasPrefix("question_") else { return false }
        let tail = id.dropFirst("question_".count)
        return !tail.isEmpty && tail.allSatisfy(\.isNumber)
    }

    /// 若是 `question_<数字>_custom`,返回其对应的 `question_<数字>`。
    nonisolated static func customBase(of id: String) -> String? {
        guard id.hasSuffix("_custom") else { return nil }
        let base = String(id.dropLast("_custom".count))
        return isQuestionID(base) ? base : nil
    }
}
