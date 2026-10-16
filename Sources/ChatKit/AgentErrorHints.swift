// @author ixxxxoooo
import ACPKit
import Foundation

/// 把 Agent 在 `session/prompt` 上返回的错误翻译成面向用户的中文说明。
///
/// 只做字符串匹配,不记录任何请求内容;无法识别时返回 `nil`,由调用方回退到原始描述。
public enum AgentErrorHints {
    /// 生成提示文案。
    /// - Parameter error: 轮次失败的错误
    /// - Returns: 命中已知模式时的中文说明,否则 `nil`
    public static func message(for error: Error) -> String? {
        let text = ((error as? JSONRPCError)?.message ?? error.localizedDescription).lowercased()
        if text.contains("prompt_rendering_failed") {
            return String(localized: "上游模型无法把本会话的历史渲染成提示(常见于免费/预览模型对历史格式较挑剔)。这不是本机问题:请重试一次,仍失败就新建对话或换一个模型。")
        }
        if text.contains("freetiererror") {
            return String(localized: "该免费模型只允许 OpenCode 官方客户端使用:请改用 OpenCode Go 端点或换一个模型。")
        }
        if text.contains("rate limit") || text.contains("too many requests") {
            return String(localized: "上游触发限流,请稍后再试。")
        }
        return nil
    }
}
