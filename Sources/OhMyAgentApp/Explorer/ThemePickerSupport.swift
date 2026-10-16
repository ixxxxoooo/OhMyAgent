// @author ixxxxoooo
// 主题选择与个性化展示支持:为各主题提供生活化标语、色盘提取、分类徽章,
// 供中央搜索窗(HubSearch)与设置页的主题选择器复用。

import DesignSystem
import SwiftUI

/// 主题生活化文案与调色板信息。
public enum ThemePersonality {
    /// 每个主题的生活化/个性化标语(避免枯燥的纯文本名称)。
    public static func tagline(for package: ThemePackage) -> String {
        switch package.id {
        case "system":
            return String(localized: "晨昏律动 · 自适应 macOS 浅色与深色随心流转")
        case "cursor-light":
            return String(localized: "极简白昼 · 灵动清爽的现代开发者本命白")
        case "cursor-light-colorblind":
            return String(localized: "明晰蓝橙 · 蓝橙无障碍与双重护眼并存")
        case "cursor-dark":
            return String(localized: "沉浸暗黑 · 经典现代的夜行者代码工坊")
        case "cursor-dark-hc":
            return String(localized: "高对比纯黑 · 极致纯粹锐利、无冗余色差")
        case "anthropic-light":
            return String(localized: "暖调燕麦 · 质朴温润的人文纸张质感")
        case "anthropic-dark":
            return String(localized: "温暖大地 · 沉稳内敛的克制黑金美学")
        case "claude-dark":
            return String(localized: "复古极客 · 终端黑底与纯粹思维碰撞")
        case "claude-light":
            return String(localized: "米白温润 · 舒适耐看无眩光的阅读体验")
        case "claude-dark-daltonized":
            return String(localized: "深色色盲友好 · 强化反差的明澈视界")
        case "claude-light-daltonized":
            return String(localized: "浅色色盲友好 · 柔和对比的无障关怀")
        case "claude-dark-ansi":
            return String(localized: "硬核 ANSI · 纯正终端 16 色老极客情怀")
        case "claude-light-ansi":
            return String(localized: "高亮 ANSI · 经典终端命令行纯正风味")
        case "opencode-dark":
            return String(localized: "蜜桃落日 · 潮酷活力的现代 TUI 极客范")
        case "opencode-light":
            return String(localized: "青蓝雅致 · 晨光微熹的明澈清朗")
        case "nord":
            return String(localized: "北欧极地 · 冰川极夜的清冽冷蓝静谧")
        case "solarized-dark":
            return String(localized: "传奇暗青 · 经久不衰的科学护眼名作")
        case "solarized-light":
            return String(localized: "经典暖黄 · 专为阅读深思打磨的经典")
        case "dracula":
            return String(localized: "哥特魅影 · 优雅暗夜吸血鬼与魅惑紫")
        case "tokyo-night":
            return String(localized: "东京霓虹 · 赛博都市雨夜的流光幻彩")
        case "github-light":
            return String(localized: "开源本色 · 全球开发者最熟悉的纯白")
        case "github-dark":
            return String(localized: "夜间工坊 · 亲切自然的 GitHub 官方夜色")
        case "gruvbox-dark":
            return String(localized: "复古暖金 · 胶片旧时光般的温暖复古")
        case "catppuccin-mocha":
            return String(localized: "猫咪摩卡 · 软萌治愈的温暖甜品暗色")
        case "mono-ink":
            return String(localized: "水墨丹青 · 纯粹黑白、心无旁骛的极简")
        default:
            return String(localized: "专属定制 · 属于你的独一无二调色盘")
        }
    }

    /// 从主题提取 4 个代表性色块(背景、文字前景、主强调色、次强调色)。
    public static func swatches(for package: ThemePackage) -> [Color] {
        guard let p = package.palette else {
            // 跟随系统:展示经典多色圆点
            return [
                Color(nsColor: .windowBackgroundColor), // ui-lint:allow 「跟随系统」预览需展示真实的 macOS 系统色
                Color(nsColor: .labelColor), // ui-lint:allow 同上
                Color(nsColor: .controlAccentColor),
                OMColors.accent2
            ]
        }
        return [
            p.surface.color,
            p.editorForeground.color,
            p.accent.color,
            p.accent2.color
        ]
    }

    /// 明暗徽标文本与着色。
    public static func toneBadge(for package: ThemePackage) -> (text: String, bg: Color, fg: Color) {
        switch package.tone {
        case .system:
            return (package.tone.displayName, OMColors.accent.opacity(0.12), OMColors.accent)
        case .dark:
            return (package.tone.displayName, OMColors.accent2.opacity(0.15), OMColors.accent2)
        case .light:
            return (package.tone.displayName, OMColors.warning.opacity(0.15), OMColors.warning)
        }
    }
}

extension ThemeTone {
    public var displayName: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }
}
