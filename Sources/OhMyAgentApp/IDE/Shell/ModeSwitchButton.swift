// @author ixxxxoooo
// 模式切换按钮:Agent 窗口右上角的「编辑器 ↗」与 IDE 窗口右上角的「Agents Window ↗」共用,
// 宽度同为 `TitlebarMetrics.modeSwitchWidth`,标题栏右侧簇在两个窗口间不跳动。⌥ 点击(Agent → IDE)强制新开窗口。

import AppKit
import DesignSystem
import IconKit
import SwiftUI

/// 模式切换按钮。
struct ModeSwitchButton: View {
    /// 切换目标
    enum Target {
        /// 去 IDE 窗口
        case ide
        /// 回 Agent 窗口
        case agent
    }

    let target: Target

    var body: some View {
        let shortcut = ShortcutStore.shared.binding(for: .switchWindowMode).display
        Button(action: perform) {
            HStack(spacing: 4) {
                Text(title)
                Image.om("external-link", size: 12)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(target == .agent ? OMButtonStyle.omPrimary : OMButtonStyle.omSecondary)
        .frame(width: TitlebarMetrics.modeSwitchWidth)
        .omTooltip(tooltip + " (\(shortcut))")
        .accessibilityLabel(tooltip)
    }

    private var title: String {
        target == .ide ? String(localized: "编辑器") : String(localized: "Agents Window")
    }

    private var tooltip: String {
        target == .ide ? String(localized: "在 IDE 窗口中打开当前项目(⌥ 点击新开窗口)") : String(localized: "回到 Agent 窗口")
    }

    /// 上一次切换的时间:切换含淡入淡出动画,双击的第二下会落在过渡中的窗口上,
    /// 把刚切过去的窗口又切回来或隐藏掉,所以过渡期内忽略重复点击。
    private static var lastSwitch = Date.distantPast

    private func perform() {
        guard Date().timeIntervalSince(Self.lastSwitch) > 0.6 else { return }
        Self.lastSwitch = Date()
        switch target {
        case .ide:
            IDEWindowManager.shared.switchToIDE(forceNew: NSEvent.modifierFlags.contains(.option))
        case .agent:
            IDEWindowManager.shared.switchToAgent()
        }
    }
}
