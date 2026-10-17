// @author ixxxxoooo
// Elicitation(Agent 向用户提问):解析 `elicitation/create` 的 form / url 模式,
// 产出可绑定的表单模型,并把用户的回答序列化回协议响应。
// Claude Code 的 AskUserQuestion 与 MCP 服务器的表单请求都经由这里呈现。

import ACPKit
import Foundation
import Observation

/// 表单字段类别。
public enum ElicitFieldKind: Sendable, Equatable {
    case text
    case number(isInteger: Bool)
    case boolean
    case single(options: [ElicitOption])
    case multi(options: [ElicitOption])
}

/// 可选项。
public struct ElicitOption: Sendable, Hashable, Identifiable {
    public var id: String { value }
    public var value: String
    public var title: String
    public var description: String?
}

/// 表单字段(带用户输入状态)。
@MainActor
@Observable
public final class ElicitField: Identifiable {
    public nonisolated let id: String
    public let title: String
    public let detail: String?
    public let kind: ElicitFieldKind
    public let isRequired: Bool
    public var text = ""
    public var flag = false
    public var selection: Set<String> = []

    init(id: String, title: String, detail: String?, kind: ElicitFieldKind, isRequired: Bool, defaultValue: JSONValue?) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.isRequired = isRequired
        switch (kind, defaultValue) {
        case (.boolean, .some(.bool(let value))): flag = value
        case (.text, .some(.string(let value))): text = value
        case (.single, .some(.string(let value))): selection = [value]
        default: break
        }
    }

    /// 当前输入是否满足该字段的要求。
    public var isSatisfied: Bool {
        guard isRequired else { return true }
        switch kind {
        case .text: return !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .number: return Double(text) != nil
        case .boolean: return true
        case .single, .multi: return !selection.isEmpty
        }
    }

    /// 序列化为协议值;未填写返回 nil。
    var jsonValue: JSONValue? {
        switch kind {
        case .text:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .string(text)
        case .number(let isInteger):
            guard let number = Double(text) else { return nil }
            return isInteger ? .int(Int(number)) : .double(number)
        case .boolean:
            return .bool(flag)
        case .single:
            return selection.first.map { .string($0) }
        case .multi(let options):
            // 按选项原始顺序输出
            let ordered = options.map(\.value).filter { selection.contains($0) }
            return ordered.isEmpty ? nil : .array(ordered.map { .string($0) })
        }
    }
}

/// 提问模式。
public enum ElicitMode: Sendable {
    case form
    case url(URL)
}

/// 待回答的提问。
@MainActor
@Observable
public final class ElicitationPrompt: Identifiable {
    public nonisolated let id = UUID()
    public let message: String
    public let mode: ElicitMode
    public let fields: [ElicitField]
    public var isResolved = false
    /// 结果快照(AskUserQuestion 形态在回答/跳过/取消时生成;通用表单为 nil)
    public private(set) var outcome: ElicitationOutcome?
    private var continuation: CheckedContinuation<JSONValue, Never>?

    init(message: String, mode: ElicitMode, fields: [ElicitField], continuation: CheckedContinuation<JSONValue, Never>) {
        self.message = message
        self.mode = mode
        self.fields = fields
        self.continuation = continuation
    }

    /// 全部必填项是否已满足。
    public var canSubmit: Bool { fields.allSatisfy(\.isSatisfied) }

    /// 提交回答。
    public func accept() {
        if !isResolved { outcome = makeOutcome(state: .answered) }
        var content: [String: JSONValue] = [:]
        for field in fields {
            if let value = field.jsonValue { content[field.id] = value }
        }
        resolve(["action": "accept", "content": .object(content)])
    }

    /// 确认 URL 模式(用户已打开链接)。
    public func acceptURL() {
        resolve(["action": "accept"])
    }

    /// 拒绝回答。
    public func decline() {
        if !isResolved { outcome = makeOutcome(state: .skipped) }
        resolve(["action": "decline"])
    }

    /// 取消(例如轮次被取消或窗口关闭)。
    public func cancel() {
        if !isResolved { outcome = makeOutcome(state: .cancelled) }
        resolve(["action": "cancel"])
    }

    private func resolve(_ value: JSONValue) {
        guard let continuation else { return }
        self.continuation = nil
        isResolved = true
        continuation.resume(returning: value)
    }
}

/// 解析器(纯函数,便于测试)。
public enum ElicitationParser {
    /// 解析请求中的字段定义。
    /// - Parameter params: `elicitation/create` 的参数
    /// - Returns: 字段规格(尚未绑定状态)
    @MainActor
    public static func fields(from params: JSONValue) -> [ElicitField] {
        guard let schema = params["requestedSchema"],
              let properties = schema["properties"]?.objectValue else { return [] }
        let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        // 字典无序,按自然顺序排序(question_2 在 question_10 之前),使 question_N 与 question_N_custom 相邻
        let keys = properties.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return keys.compactMap { key in
            guard let spec = properties[key] else { return nil }
            let title = spec["title"]?.stringValue ?? ""
            let detail = spec["description"]?.stringValue
            let kind = fieldKind(spec)
            return ElicitField(id: key, title: title.isEmpty ? key : title, detail: detail, kind: kind,
                               isRequired: required.contains(key), defaultValue: spec["default"])
        }
    }

    static func options(_ list: [JSONValue]) -> [ElicitOption] {
        list.compactMap { item in
            if let plain = item.stringValue { return ElicitOption(value: plain, title: plain) }
            guard let value = item["const"]?.stringValue else { return nil }
            return ElicitOption(value: value, title: item["title"]?.stringValue ?? value, description: item["description"]?.stringValue)
        }
    }

    static func fieldKind(_ spec: JSONValue) -> ElicitFieldKind {
        let type = spec["type"]?.stringValue
        if type == "array" {
            let items = spec["items"]
            let list = items?["anyOf"]?.arrayValue ?? items?["oneOf"]?.arrayValue ?? items?["enum"]?.arrayValue ?? []
            return .multi(options: options(list))
        }
        if let one = spec["oneOf"]?.arrayValue { return .single(options: options(one)) }
        if let values = spec["enum"]?.arrayValue {
            let names = spec["enumNames"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var parsed = options(values)
            if names.count == parsed.count {
                parsed = zip(parsed, names).map { ElicitOption(value: $0.value, title: $1, description: $0.description) }
            }
            return .single(options: parsed)
        }
        switch type {
        case "boolean": return .boolean
        case "integer": return .number(isInteger: true)
        case "number": return .number(isInteger: false)
        default: return .text
        }
    }
}
