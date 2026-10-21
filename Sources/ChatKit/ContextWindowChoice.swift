// @author ixxxxoooo
// 输入框「上下文」选择器的档位:控制自动压缩窗口(CLAUDE_CODE_AUTO_COMPACT_WINDOW),
// 与设置页「上下文上限」是同一个偏好。纯逻辑,无视图。
// 范围 10 万 ~ 100 万与 Claude Code 对 autoCompactWindow 的校验一致。

import Foundation

/// 上下文窗口(自动压缩窗口)的预设档位。
public enum ContextWindowChoice {
    /// 预设档位(token);0 表示「自动」(交给 Claude Code 按模型决定)。顺序即菜单顺序。
    /// 用户没选过时取 200K(`SessionOptions.defaultAutoCompactWindow`)。
    public static let presets: [Int] = [0, 100_000, 200_000, 300_000, 500_000, 1_000_000]

    /// 档位的简短标题:`0` → 自动,`200_000` → `200K`,`1_000_000` → `1M`。
    /// - Parameter tokens: token 数
    /// - Returns: 展示文本
    public static func title(for tokens: Int) -> String {
        guard tokens > 0 else { return String(localized: "自动") }
        if tokens >= 1_000_000, tokens % 1_000_000 == 0 { return "\(tokens / 1_000_000)M" }
        if tokens % 1_000 == 0 { return "\(tokens / 1_000)K" }
        return "\(tokens)"
    }

    /// 把任意偏好值归一为有效值:≤ 0 为自动(0),其余夹到允许范围。
    /// - Parameter tokens: 偏好里的 token 数
    /// - Returns: 归一后的值
    public static func normalized(_ tokens: Int) -> Int {
        guard tokens > 0 else { return 0 }
        return min(max(tokens, SessionOptions.autoCompactRange.lowerBound), SessionOptions.autoCompactRange.upperBound)
    }
}
