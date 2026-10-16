// @author ixxxxoooo
// 主题桥接:把应用层的主题令牌注册给不依赖 DesignSystem 的纯模块(如 MermaidKit)。

import DesignSystem
import MermaidKit
import SwiftUI

/// 主题桥接注册。
enum ThemeBridges {
    /// 注册 Mermaid 配色提供者:每次创建调色板时都按当前主题取色,切换主题后重新渲染即生效。
    static func register() {
        MermaidPalette.themeProvider = { _ in
            MermaidTheme(
                background: OMColors.surface,
                text: OMColors.primaryText,
                subtleText: OMColors.secondaryText,
                nodeFill: OMColors.card,
                nodeStroke: OMColors.tertiaryText,
                edge: OMColors.secondaryText,
                groupFill: OMColors.subtleFill,
                groupStroke: OMColors.hairline,
                noteFill: OMColors.warning.opacity(0.18),
                activation: OMColors.pressedFill,
                success: OMColors.success,
                danger: OMColors.danger,
                warning: OMColors.warning,
                accents: (0..<8).map { OMColors.chart($0) }
            )
        }
    }
}
