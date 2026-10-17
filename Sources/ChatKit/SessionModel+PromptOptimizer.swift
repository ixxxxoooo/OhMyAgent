// @author ixxxxoooo
// 会话的提示词优化入口:选择通道(演示 / 本机网关小模型 / 本机 claude),返回改写后的草稿。

import AgentHost
import Foundation

extension SessionModel {
    /// 优化一段提示词。通道优先级:演示模式 → 已映射提供商的本机网关 → 本机 `claude -p`。
    /// - Parameter draft: 输入框草稿
    /// - Returns: 改写后的提示词
    /// - Throws: `PromptOptimizeError`(不可优化、无可用通道、请求失败)
    public func optimizePrompt(_ draft: String) async throws -> String {
        guard PromptOptimizer.isOptimizable(draft) else { throw PromptOptimizeError.notOptimizable }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if Toolchain.isDemoMode { return PromptOptimizer.demoRewrite(text) }
        if let gateway = utilityGateway {
            guard let result = await PromptOptimizer.viaGateway(gateway: gateway.url, model: gateway.alias, text: text) else { throw PromptOptimizeError.failed }
            return result
        }
        guard activeDescriptor.kind == .claudeACP else { throw PromptOptimizeError.unavailable }
        let tools = await Toolchain.shared.resolve()
        guard let claude = tools.claudePath else { throw PromptOptimizeError.unavailable }
        guard let result = await PromptOptimizer.viaClaude(claude: claude, environment: tools.environment, cwd: workspace.path, text: text) else { throw PromptOptimizeError.failed }
        return result
    }
}
