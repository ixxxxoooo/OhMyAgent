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

    /// 恢复(`session/load` / `session/resume`)失败的归类。
    public enum RestoreFailure: Equatable, Sendable {
        /// 引擎里没有这个会话(属于别的引擎、从未落盘的空会话、已被删除)
        case notFound
        /// 引擎启动/握手阶段就失败(命令找不到、进程退出)
        case engineUnavailable
        /// 其他错误
        case other
    }

    /// 把恢复失败的错误归类。
    /// - Parameter error: 恢复请求抛出的错误
    /// - Returns: 失败类别
    public static func classifyRestore(_ error: Error) -> RestoreFailure {
        if let rpc = error as? JSONRPCError, rpc.code == -32002 { return .notFound }
        var text = ((error as? JSONRPCError)?.message ?? error.localizedDescription).lowercased()
        if let rpc = error as? JSONRPCError, let data = rpc.data { text += " " + "\(data)".lowercased() }
        let notFoundMarkers = ["valid session id", "session not found", "no conversation found", "unknown session", "does not exist", "no session"]
        if notFoundMarkers.contains(where: text.contains) { return .notFound }
        if text.contains("no such file") || text.contains("broken pipe") || text.contains("connection closed") { return .engineUnavailable }
        return .other
    }

    /// 恢复失败时给用户的中文说明。
    /// - Parameter error: 恢复请求抛出的错误
    /// - Returns: 面向用户的说明
    public static func restoreMessage(for error: Error) -> String {
        switch classifyRestore(error) {
        case .notFound:
            return String(localized: "当前引擎找不到这个会话:它可能属于其他引擎、从未发送过消息,或已被删除。")
        case .engineUnavailable:
            return String(localized: "引擎已退出或无法启动,没能恢复这个会话。请到「设置 → Agent」检查命令是否可用后重试。")
        case .other:
            return String(localized: "打开会话失败:\(error.localizedDescription)")
        }
    }
}
