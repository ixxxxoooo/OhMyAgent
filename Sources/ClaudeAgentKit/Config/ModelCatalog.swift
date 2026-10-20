// @author ixxxxoooo
// 模型目录:解析 CLI 返回的模型清单,按偏好/恢复模型匹配,生成模型选择配置项与版本化显示名。

import ACPKit
import Foundation

/// `claude` 报告的一个可选模型。
struct ModelInfo: Equatable, Sendable {
    var value: String
    var displayName: String
    var description: String
    var resolvedModel: String?
    var supportsEffort = false
    var supportedEffortLevels: [String] = []
    var supportsFastMode = false
    var supportsAutoMode = false

    /// 从 CLI `initialize` 响应的模型元素构造。
    init?(_ json: JSONValue) {
        guard let value = json["value"]?.nonEmptyString else { return nil }
        self.value = value
        displayName = json["displayName"]?.stringValue ?? value
        description = json["description"]?.stringValue ?? ""
        resolvedModel = json["resolvedModel"]?.nonEmptyString
        supportsEffort = json["supportsEffort"]?.boolValue ?? false
        supportedEffortLevels = (json["supportedEffortLevels"]?.arrayValue ?? []).compactMap(\.stringValue)
        supportsFastMode = json["supportsFastMode"]?.boolValue ?? false
        supportsAutoMode = json["supportsAutoMode"]?.boolValue ?? false
    }

    init(value: String, displayName: String, description: String = "", resolvedModel: String? = nil) {
        self.value = value
        self.displayName = displayName
        self.description = description
        self.resolvedModel = resolvedModel
    }
}

/// 会话当前的模型选择状态。
struct ModelState: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var modelId: String
        var name: String
        var description: String
    }
    var available: [Entry]
    var currentModelId: String
}

/// 正则小工具。
enum Rx {
    /// 返回首个匹配的各捕获组(组 0 为整体)。
    static func match(_ pattern: String, _ text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let found = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    static func replace(_ pattern: String, _ text: String, with template: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func test(_ pattern: String, _ text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> Bool {
        match(pattern, text, options: options) != nil
    }
}

/// 模型匹配与目录构造(与 Node 适配器 `session-model.js` 对齐)。
enum ModelCatalog {
    static let configId = "model"
    private static let contextHintPattern = "\\[(\\d+m)\\]$"
    private static let contextSuffixPattern = "-(\\d+m)$"

    static func stripContextHints(_ value: String) -> String {
        Rx.replace(contextSuffixPattern, Rx.replace("\\[\\d+m\\]", value, with: ""), with: "")
    }

    static func canonicalize(_ value: String) -> String {
        Rx.replace(contextSuffixPattern, value.trimmingCharacters(in: .whitespaces).lowercased(), with: "[$1]")
    }

    static func contextHint(_ value: String) -> String? {
        Rx.match(contextHintPattern, canonicalize(value))?[1]
    }

    static func familyVersion(_ value: String) -> String? {
        guard let groups = Rx.match("\\b(\\d+)(?:[-.](\\d+))?\\b", stripContextHints(value)), let major = groups[1] else { return nil }
        if let minor = groups[2] { return "\(major).\(minor)" }
        return major
    }

    static func versionsCompatible(_ preference: String, _ candidate: ModelInfo) -> Bool {
        guard let preferred = familyVersion(preference) else { return true }
        let candidateVersion = familyVersion(candidate.value) ?? familyVersion(candidate.displayName) ?? familyVersion(candidate.description)
        guard let candidateVersion else { return true }
        return preferred == candidateVersion
    }

    private static func displayModelVersion(_ model: ModelInfo, family: String) -> String? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: family))[-\\s]+(\\d+)(?:[-.](\\d+))?"
        for source in [model.resolvedModel, model.description, model.value] {
            guard let source, let groups = Rx.match(pattern, source), let major = groups[1] else { continue }
            if let minor = groups[2] { return "\(major).\(minor)" }
            return major
        }
        return nil
    }

    /// 给「Opus」「Sonnet」这类无版本显示名补上版本号。
    static func versionedDisplayName(_ model: ModelInfo) -> String {
        let versionable = "^(?:Claude\\s+)?([a-z][a-z0-9-]*)(?:\\s+\\d+(?:\\.\\d+)?)?(?:\\s+\\(\\d+[mk]\\s+context\\))?$"
        guard let groups = Rx.match(versionable, model.displayName), let family = groups[1],
              let version = displayModelVersion(model, family: family) else { return model.displayName }
        let suffixPattern = "\\s+\\((\\d+[mk])\\s+context\\)$"
        let contextSuffix = Rx.match(suffixPattern, model.displayName)
        let keepsContext = contextSuffix.map { match in
            guard let size = match[1] else { return false }
            return Rx.test("\\b\(size)\\s+context\\b", model.description)
        } ?? false
        let withoutContext = Rx.replace(suffixPattern, model.displayName, with: "")
        if Rx.test("\\b\\d+(?:\\.\\d+)?\\b", withoutContext) { return keepsContext ? withoutContext : model.displayName }
        if keepsContext || contextSuffix == nil { return "\(withoutContext) \(version)" }
        return "\(withoutContext) \(version)\(contextSuffix?[0] ?? "")"
    }

    private static func tokenize(_ model: String) -> (tokens: [String], contextHint: String?) {
        let lower = model.trimmingCharacters(in: .whitespaces).lowercased()
        let hint = Rx.match(contextHintPattern, lower)?[1]?.lowercased()
        let spaced = Rx.replace(contextHintPattern, lower, with: " $1 ")
        let tokens = spaced.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init)
            .map { token -> String in
                if token == "opusplan" { return "opus" }
                if token == "best" || token == "default" { return "" }
                return token
            }
            .filter { !$0.isEmpty && $0 != "claude" }
            .filter { token in token.contains(where: \.isLetter) || token.hasSuffix("m") }
        return (tokens, hint)
    }

    private static func score(_ model: ModelInfo, tokens: [String], contextHint: String?) -> Int {
        let haystack = "\(model.value) \(model.displayName)".lowercased()
        var total = 0
        var nonHintMatched = false
        for token in tokens where haystack.contains(token) {
            if token != contextHint { nonHintMatched = true }
            total += token == contextHint ? 3 : 1
        }
        return contextHint != nil && !nonHintMatched ? 0 : total
    }

    /// 把偏好字符串(如 `sonnet`、`claude-opus-4-7[1m]`)匹配到目录里的模型。
    static func resolvePreference(_ models: [ModelInfo], _ preference: String) -> ModelInfo? {
        let trimmed = preference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let canonicalPreference = canonicalize(trimmed)
        if let direct = models.first(where: { $0.value == trimmed || canonicalize($0.value) == canonicalPreference || $0.displayName.lowercased() == lower }) { return direct }
        let matchesResolved: (ModelInfo) -> Bool = { $0.resolvedModel.map { canonicalize($0) == canonicalPreference } ?? false }
        if let resolved = models.first(where: { $0.value != "default" && matchesResolved($0) }) ?? models.first(where: matchesResolved) { return resolved }
        let preferenceHint = contextHint(trimmed)
        if let included = models.first(where: { model in
            guard versionsCompatible(trimmed, model), contextHint(model.value) == preferenceHint else { return false }
            let value = model.value.lowercased()
            return value.contains(lower) || model.displayName.lowercased().contains(lower) || lower.contains(value)
        }) { return included }
        let (tokens, hint) = tokenize(trimmed)
        guard !tokens.isEmpty else { return nil }
        var best: ModelInfo?
        var bestScore = 0
        for model in models where versionsCompatible(trimmed, model) {
            let value = score(model, tokens: tokens, contextHint: hint)
            if value > 0, best == nil || value > bestScore { best = model; bestScore = value }
        }
        return best
    }

    /// 按恢复会话时实际使用的模型名找回目录项。
    static func matchResumed(_ models: [ModelInfo], liveModel: String) -> ModelInfo {
        let live = canonicalize(liveModel)
        let defaultEntry = models.first { $0.value == "default" }
        let defaultResolved = defaultEntry?.resolvedModel.map(canonicalize)
        if let defaultEntry, defaultResolved == live { return defaultEntry }
        if let exact = models.first(where: { $0.resolvedModel.map { canonicalize($0) == live } ?? false }) { return exact }
        if let defaultEntry, let defaultResolved, stripContextHints(defaultResolved) == stripContextHints(live) { return defaultEntry }
        return resolvePreference(models, liveModel) ?? ModelInfo(value: liveModel, displayName: liveModel)
    }

    // MARK: 允许列表

    private static let familyAliases: Set<String> = ["opus", "sonnet", "haiku", "fable"]

    static func normalizeModelId(_ value: String) -> String {
        var id = stripContextHints(value.trimmingCharacters(in: .whitespaces).lowercased())
        if let range = id.range(of: "anthropic.", options: .backwards) { id = String(id[range.upperBound...]) }
        id = Rx.replace("@.*$", id, with: "")
        id = Rx.replace("-v\\d+(?::\\d+)?$", id, with: "")
        id = Rx.replace("-fast$", id, with: "")
        id = Rx.replace("-\\d{8}$", id, with: "")
        return id
    }

    static func isDenied(_ modelId: String, denied: [String]) -> Bool {
        let id = normalizeModelId(modelId)
        guard !id.isEmpty else { return false }
        return denied.contains { entry in
            let item = normalizeModelId(entry)
            guard !item.isEmpty else { return false }
            if familyAliases.contains(item) { return id == item || id.contains("-\(item)") }
            return id == item || id.hasPrefix("\(item)-")
        }
    }

    /// 应用设置里的 `availableModels` 允许列表与 `modelOverrides`。
    static func applyAllowlist(_ sdkModels: [ModelInfo], allowlist: [String], overrides: [String: String], denied: [String], customOption: String?) -> [ModelInfo] {
        let defaultModel = sdkModels.first { $0.value == "default" } ?? ModelInfo(value: "default", displayName: "Default")
        var result = [defaultModel]
        var seen: Set<String> = [defaultModel.value]
        let withoutDefault = sdkModels.filter { $0.value != "default" }
        for entry in allowlist {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || seen.contains(trimmed) { continue }
            let effective = overrides[trimmed] ?? trimmed
            if seen.contains(effective) { continue }
            let match = resolvePreference(withoutDefault, trimmed)
            if [trimmed, effective, match?.resolvedModel].contains(where: { $0.map { isDenied($0, denied: denied) } ?? false }) { continue }
            if var match {
                match.value = effective
                result.append(match)
            } else {
                result.append(ModelInfo(value: effective, displayName: trimmed))
            }
            seen.insert(effective)
        }
        if let customOption, !customOption.isEmpty, !seen.contains(customOption), let custom = sdkModels.first(where: { $0.value == customOption }) {
            result.append(custom)
        }
        return result
    }

    // MARK: 配置项

    /// 构造模型选择配置项。
    static func configOption(state: ModelState, infos: [ModelInfo]) -> JSONValue {
        let defaultInfo = infos.first { $0.value == "default" }
        let options: [JSONValue] = state.available.map { entry in
            if entry.modelId == "default", let resolved = defaultInfo?.resolvedModel {
                let named = infos.first { $0.value != "default" && $0.resolvedModel == resolved }
                return ["value": "default", "name": .string(entry.name), "description": .string(named?.displayName ?? resolved)]
            }
            return JSONValue.make([("value", .string(entry.modelId)), ("name", .string(entry.name)), ("description", entry.description.isEmpty ? nil : .string(entry.description))])
        }
        return ["id": "model", "name": "Model", "description": "AI model to use", "category": "model", "type": "select",
                "currentValue": .string(state.currentModelId), "options": .array(options)]
    }

    /// 由目录构造展示用的模型状态(重名时退回原始显示名)。
    static func state(models: [ModelInfo], currentModelId: String) -> ModelState {
        let names = models.map(versionedDisplayName)
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        let entries = models.enumerated().map { index, model in
            ModelState.Entry(modelId: model.value, name: counts[names[index]] == 1 ? names[index] : model.displayName, description: model.description)
        }
        return ModelState(available: entries, currentModelId: currentModelId)
    }

    /// 由 `inferContextWindowFromModel` 推断:文本中出现 `1m` 视为 100 万上下文。
    static func inferContextWindow(_ texts: String?...) -> Int? {
        texts.contains { $0.map { Rx.test("\\b1m\\b", $0) } ?? false } ? 1_000_000 : nil
    }
}
