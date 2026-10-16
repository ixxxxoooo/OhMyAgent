// @author ixxxxoooo
// 上游错误的可操作提示:把 OpenCode 等网关的特定错误码翻译成中文指引。

import Foundation

/// 上游错误提示。
public enum UpstreamHints {
    /// 识别响应正文里的已知错误,返回对应的中文指引。
    /// - Parameter body: 上游响应体
    /// - Returns: 识别到时返回提示;否则 nil
    public static func message(for body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        if text.contains("FreeTierError") {
            return String(localized: "该免费模型仅限 OpenCode 官方客户端在 Zen 端点使用。请把提供商换成「OpenCode Go」(地址 https://opencode.ai/zen/go/v1,OpenAI 协议),Go 订阅里同样包含该免费模型。")
        }
        if text.contains("MissingSessionID") {
            return String(localized: "上游要求携带 x-opencode-session 会话头。请在提供商里开启「OpenCode 兼容请求头」。")
        }
        if text.contains("ModelProtocolUnsupported") {
            return String(localized: "该模型不支持当前提供商的协议:请把协议切换为另一种(OpenAI / Anthropic),或换用其他模型。")
        }
        if text.contains("error code: 1010") {
            return String(localized: "上游(Cloudflare)拦截了该请求(1010):缺少客户端标识。请开启「OpenCode 兼容请求头」,或换用其他提供商。")
        }
        return nil
    }
}
