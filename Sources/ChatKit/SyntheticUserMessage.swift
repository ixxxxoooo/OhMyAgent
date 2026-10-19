// @author ixxxxoooo
// Claude Code 写进会话记录的「合成用户消息」识别:中断、拒绝、工具调用未完成等。
// 这些文本不是用户输入,历史重放时若按普通用户气泡显示会让人误以为是自己发的。

import Foundation

/// 合成用户消息的显示方式。
public enum SyntheticUserMessage: Equatable, Sendable {
    /// 用户中断请求(淡色分隔行,附带中文说明)
    case interrupted(String)
    /// 用户拒绝了某个操作
    case denied
    /// 仅给模型看的系统说明(工具调用未完成/跳过等),界面不显示
    case hidden

    /// 中断类消息的前缀(兼容后续新增的 `[Request interrupted by user …]` 变体)
    private static let interruptPrefix = "[Request interrupted by user"
    /// 仅给模型看的括号说明前缀
    private static let hiddenPrefixes = ["[Tool call did not complete", "[Tool call interrupted", "[Tool call result not in this copy", "[Tool call skipped"]
    /// 权限拒绝的固定开头
    private static let deniedPrefix = "The user doesn't want to take this action right now"

    /// 识别一段用户文本是否为合成消息。
    /// - Parameter text: 用户消息原文
    /// - Returns: 命中的类型;普通用户输入返回 nil
    public static func classify(_ text: String) -> SyntheticUserMessage? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix(interruptPrefix) {
            let forTool = value.contains("for tool use")
            return .interrupted(forTool ? ChatL10n.t("已中断(工具调用中)") : ChatL10n.t("已中断"))
        }
        if value.hasPrefix(deniedPrefix) { return .denied }
        if hiddenPrefixes.contains(where: { value.hasPrefix($0) }) { return .hidden }
        return nil
    }
}
