// @author ixxxxoooo
// 编辑器内「⌘K 行内编辑」的提示词与结果清洗:把选区 + 指令交给辅助模型,拿回替换文本。
// 通道与提示词优化一致(演示模式 → 网关小模型 → 本机 claude -p),不经过会话,不产生时间线条目。

import AgentHost
import Foundation

/// 行内编辑错误。
public enum InlineEditError: Error, Equatable, Sendable, LocalizedError {
    /// 指令为空
    case emptyInstruction
    /// 没有可用通道
    case unavailable
    /// 请求失败或返回空内容
    case failed

    public var errorDescription: String? {
        switch self {
        case .emptyInstruction: String(localized: "请输入修改指令")
        case .unavailable: String(localized: "没有可用的模型通道,请先在设置里配置模型")
        case .failed: String(localized: "模型没有返回有效的修改,请重试")
        }
    }
}

/// 行内编辑的纯逻辑。
public enum InlineEdit {
    /// 系统提示词。
    public static let systemPrompt = """
    你是代码编辑助手。用户给出文件中的一段选中代码和一条修改指令,请按指令改写这段代码。
    - 只输出改写后的这段代码本身,用来直接替换原选区;不要解释、标题或前后缀。
    - 保持原有缩进、换行风格与语言风格;不要输出选区之外的代码;不要加 Markdown 代码围栏。
    - 指令含糊时做最小且合理的修改;无需修改时原样输出选区。
    """

    /// 选区允许的最大字符数(再长的选区应交给 Agent 面板)。
    public static let maxSelectionLength = 12_000

    /// 构造发给模型的用户消息。
    /// - Parameters:
    ///   - instruction: 修改指令
    ///   - path: 文件路径(取文件名)
    ///   - selected: 选中的代码
    ///   - before: 选区之前的若干行上下文
    ///   - after: 选区之后的若干行上下文
    /// - Returns: 消息文本
    public static func userMessage(instruction: String, path: String, selected: String, before: String, after: String) -> String {
        var parts = ["文件:\((path as NSString).lastPathComponent)", "指令:\(instruction.trimmingCharacters(in: .whitespacesAndNewlines))"]
        if !before.isEmpty { parts.append("选区之前的上下文:\n<before>\n\(before)\n</before>") }
        parts.append("选中的代码:\n<selection>\n\(selected)\n</selection>")
        if !after.isEmpty { parts.append("选区之后的上下文:\n<after>\n\(after)\n</after>") }
        return parts.joined(separator: "\n\n")
    }

    /// 清洗模型输出:只去掉整体包裹的代码围栏与误带的 `<selection>` 标签,保留首尾缩进与换行。
    /// - Parameter raw: 模型原始输出
    /// - Returns: 可直接替换选区的文本;空内容返回 nil
    public static func clean(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```", lines.count >= 2 {
            lines.removeFirst()
            lines.removeLast()
            text = lines.joined(separator: "\n")
        }
        for tag in ["<selection>", "</selection>"] { text = text.replacingOccurrences(of: tag, with: "") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// 演示模式的确定性改写:在选区第一行之后追加一行注释(不访问模型)。
    /// - Parameters:
    ///   - selected: 选中的代码
    ///   - instruction: 修改指令
    /// - Returns: 改写后的代码
    public static func demoRewrite(selected: String, instruction: String) -> String {
        var lines = selected.components(separatedBy: "\n")
        let indent = String((lines.first ?? "").prefix { $0 == " " || $0 == "\t" })
        lines.insert("\(indent)// 已按指令修改:\(instruction.trimmingCharacters(in: .whitespacesAndNewlines))", at: min(1, lines.count))
        return lines.joined(separator: "\n")
    }
}

extension SessionModel {
    /// 对一段选区执行行内编辑。通道优先级与提示词优化一致。
    /// - Parameters:
    ///   - instruction: 修改指令
    ///   - path: 文件路径
    ///   - selected: 选区文本
    ///   - before: 选区前的上下文
    ///   - after: 选区后的上下文
    /// - Returns: 替换选区的文本
    /// - Throws: `InlineEditError`
    public func inlineEdit(instruction: String, path: String, selected: String, before: String, after: String) async throws -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InlineEditError.emptyInstruction }
        if Toolchain.isDemoMode || ProcessInfo.processInfo.environment["OMA_AGENT"] == "fake" { return InlineEdit.demoRewrite(selected: selected, instruction: trimmed) }
        let message = InlineEdit.userMessage(instruction: trimmed, path: path, selected: selected, before: before, after: after)
        if let gateway = await UtilityModels.endpoint(for: UtilityModels.choice(for: .optimize), fallback: utilityGateway) {
            guard let result = await PromptOptimizer.viaGateway(gateway: gateway.url, model: gateway.alias, text: message, timeout: 90,
                                                                system: InlineEdit.systemPrompt, maxTokens: 8000, cleaner: InlineEdit.clean) else { throw InlineEditError.failed }
            return result
        }
        guard activeDescriptor.kind == .claudeACP else { throw InlineEditError.unavailable }
        let tools = await Toolchain.shared.resolve()
        guard let claude = tools.claudePath else { throw InlineEditError.unavailable }
        guard let result = await PromptOptimizer.viaClaude(claude: claude, environment: tools.environment, cwd: workspace.path, text: message,
                                                           timeout: .seconds(120), system: InlineEdit.systemPrompt, cleaner: InlineEdit.clean) else { throw InlineEditError.failed }
        return result
    }
}

/// Tab 幽灵补全的提示词与结果清洗。
public enum InlineSuggest {
    /// 系统提示词。
    public static let systemPrompt = """
    你是代码补全引擎。用户给出光标前后的代码(以 <cursor/> 标记光标位置),请直接续写光标处应当出现的代码。
    - 只输出要插入的文本本身,不要重复光标前已有的内容,不要解释,不要 Markdown 代码围栏。
    - 通常补全当前语句或接下来的几行,最多 8 行;不确定时输出空内容。
    """

    /// 建议的最大行数与字符数。
    public static let maxLines = 8
    public static let maxLength = 800

    /// 构造发给模型的用户消息。
    /// - Parameters:
    ///   - path: 文件路径(取文件名)
    ///   - prefix: 光标前的上下文
    ///   - suffix: 光标后的上下文
    /// - Returns: 消息文本
    public static func userMessage(path: String, prefix: String, suffix: String) -> String {
        "文件:\((path as NSString).lastPathComponent)\n\n\(prefix)<cursor/>\(suffix)"
    }

    /// 清洗模型输出:去掉围栏与误带的光标标记,限制行数与长度,保留首部缩进/空格。
    /// - Parameter raw: 模型原始输出
    /// - Returns: 可直接插入的文本;空内容返回 nil
    public static func clean(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "<cursor/>", with: "")
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeFirst() }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        text = lines.prefix(maxLines).joined(separator: "\n")
        if text.count > maxLength { text = String(text.prefix(maxLength)) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// 演示模式的确定性建议:在行尾补一段注释。
    public static let demoText = " // 幽灵补全建议"
}

extension SessionModel {
    /// 请求光标处的续写建议。只走网关小模型(不为每次停顿拉起 `claude` 进程);无通道返回 nil。
    /// - Parameters:
    ///   - path: 文件路径
    ///   - prefix: 光标前上下文
    ///   - suffix: 光标后上下文
    /// - Returns: 要插入的文本
    public func inlineSuggest(path: String, prefix: String, suffix: String) async -> String? {
        guard !prefix.isEmpty else { return nil }
        if Toolchain.isDemoMode || ProcessInfo.processInfo.environment["OMA_AGENT"] == "fake" { return InlineSuggest.demoText }
        guard let gateway = await UtilityModels.endpoint(for: UtilityModels.choice(for: .optimize), fallback: utilityGateway) else { return nil }
        return await PromptOptimizer.viaGateway(gateway: gateway.url, model: gateway.alias,
                                                text: InlineSuggest.userMessage(path: path, prefix: prefix, suffix: suffix), timeout: 20,
                                                system: InlineSuggest.systemPrompt, maxTokens: 300, cleaner: InlineSuggest.clean)
    }
}
