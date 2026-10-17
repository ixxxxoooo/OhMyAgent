// @author ixxxxoooo
// 提示词优化失败的原因(文案直接展示给用户)。

import Foundation

/// 提示词优化失败的原因(文案直接展示给用户)。
public enum PromptOptimizeError: Error, LocalizedError, Sendable, Equatable {
    /// 草稿为空,或是单个斜杠命令、过长,不适合改写
    case notOptimizable
    /// 当前没有可用的模型通道(未映射提供商、也没有 claude,或不是 Claude Code)
    case unavailable
    /// 请求失败、超时或没有拿到有效结果
    case failed

    public var errorDescription: String? {
        switch self {
        case .notOptimizable: return String(localized: "输入框里没有可优化的提示词")
        case .unavailable: return String(localized: "当前没有可用的模型来优化提示词(需要本机 claude 或已映射的模型提供商)")
        case .failed: return String(localized: "提示词优化失败,请稍后重试")
        }
    }
}
