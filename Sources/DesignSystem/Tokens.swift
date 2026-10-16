// @author ixxxxoooo
// 设计令牌:颜色、尺寸、字体。全部使用系统语义色以适配深浅色与高对比度。

import AppKit
import SwiftUI

/// 尺寸令牌。
public enum OMMetrics {
    public static let cardRadius: CGFloat = 12
    public static let controlRadius: CGFloat = 8
    public static let sidebarWidth: CGFloat = 248
    public static let toolbarHeight: CGFloat = 44
    public static let timelineMaxWidth: CGFloat = 820
    public static let spacing: CGFloat = 12
    /// 文件类型图标尺寸:内联在文字/chip/工具行文件名前
    public static let fileIconInline: CGFloat = 14
    /// 文件类型图标尺寸:列表行(资源管理器、搜索结果),与 11.5pt 小字相配,不再偏大
    public static let fileIconList: CGFloat = 14
}

/// 颜色令牌。系统主题下全部使用系统语义色;选择主题包后按调色板取色。
public enum OMColors {
    /// 时间线与编辑区背景(纯色)
    /// 系统主题:浅色 #F6F6F7(见 AGENTS.md「界面配色」)。
    public static var surface: Color {
        ThemeRuntime.palette.map { $0.surface.color } ?? contentBackground
    }
    /// 系统主题的内容区背景:浅色 #F6F6F7、深色 #1E1F22。
    public static let contentBackground = systemContentBackground
    /// 系统主题的内容区背景(与是否选了主题包无关;主题卡片预览取样用)。
    public static let systemContentBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.118, green: 0.122, blue: 0.133, alpha: 1)
            : NSColor(srgbRed: 0xF6 / 255, green: 0xF6 / 255, blue: 0xF7 / 255, alpha: 1)
    })
    /// 左右侧栏(含设置页左栏)背景:仅「跟随系统」与 Cursor 浅色主题为 #EFEFEF;其余主题取各自调色板的 `sidebarBackground`(未指定则由内容色推导)。
    public static var sidebar: Color {
        if let palette = ThemeRuntime.palette {
            return (palette.sidebarBackground
                ?? palette.surface.mixed(with: palette.editorForeground, palette.isDark ? 0.045 : 0.035)).color
        }
        return systemSidebar
    }
    /// 系统主题的侧栏背景(与是否选了主题包无关;主题卡片预览取样用)。
    public static let systemSidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.094, green: 0.098, blue: 0.110, alpha: 1)
            : NSColor(srgbRed: 0xEF / 255, green: 0xEF / 255, blue: 0xEF / 255, alpha: 1)
    })
    /// 卡片背景(纯色)
    public static var card: Color {
        if let palette = ThemeRuntime.palette { return palette.card.color }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.145, green: 0.150, blue: 0.165, alpha: 1)
                : NSColor(srgbRed: 0.975, green: 0.977, blue: 0.985, alpha: 1)
        })
    }
    /// 玻璃回退时的不透明 chrome 背景
    public static let opaqueChrome = Color(nsColor: .windowBackgroundColor)
    /// 分隔线
    public static let hairline = Color(nsColor: .separatorColor)
    public static let secondaryText = Color(nsColor: .secondaryLabelColor)
    public static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    /// 新增(绿 / 色盲主题为蓝)
    public static var diffAdded: Color { ThemeRuntime.palette.map { $0.success.color } ?? Color(nsColor: .systemGreen) }
    /// 删除(红 / 色盲主题为橙)
    public static var diffRemoved: Color { ThemeRuntime.palette.map { $0.danger.color } ?? Color(nsColor: .systemRed) }
    public static var warning: Color { ThemeRuntime.palette.map { $0.warning.color } ?? Color(nsColor: .systemOrange) }
    /// 成功色。
    public static var success: Color { diffAdded }
    /// 警示/危险色(负向语义:删除、报错)。
    public static var danger: Color { diffRemoved }
    /// 强调色实底上的前景(按钮文字、选中徽标):恒为白色,保证在任意强调色上的对比度。
    public static let onAccent = Color.white
    /// 主强调色:用户选择 > 主题默认 > 系统强调色。
    public static var accent: Color { ThemeRuntime.accent?.color ?? Color.accentColor }
    /// 第二强调色:链接、次要徽标;未指定时回退主强调色。
    public static var accent2: Color { ThemeRuntime.accent2?.color ?? accent }
}

/// Diff 配色:全部为不透明预混合色(随主题切换),避免半透明叠加在行与行之间留下接缝、边缘发灰。
public enum OMDiffPalette {
    /// 行类别。
    public enum Kind: Sendable { case added, removed, context, empty }

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// 行号槽相对正文的混合比例:深色主题提亮、浅色主题压暗。
    private static func gutterMix(_ bg: ThemeRGB, toward bar: ThemeRGB, dark: Bool) -> ThemeRGB {
        bg.mixed(with: bar, dark ? 0.16 : 0.10)
    }

    /// 正文区背景。
    public static func background(_ kind: Kind) -> Color {
        if let palette = ThemeRuntime.palette {
            switch kind {
            case .added: return palette.diffAdded.color
            case .removed: return palette.diffRemoved.color
            case .context: return palette.editorBackground.color
            case .empty: return palette.editorBackground.mixed(with: palette.editorForeground, 0.04).color
            }
        }
        switch kind {
        case .added: return addedBackground
        case .removed: return removedBackground
        case .context: return contextBackground
        case .empty: return emptyBackground
        }
    }

    /// 行号槽背景(比正文深一档)。
    public static func gutter(_ kind: Kind) -> Color {
        if let palette = ThemeRuntime.palette {
            switch kind {
            case .added: return gutterMix(palette.diffAdded, toward: palette.success, dark: palette.isDark).color
            case .removed: return gutterMix(palette.diffRemoved, toward: palette.danger, dark: palette.isDark).color
            case .context: return palette.gutterBackground.color
            case .empty: return palette.gutterBackground.mixed(with: palette.editorForeground, 0.02).color
            }
        }
        switch kind {
        case .added: return addedGutter
        case .removed: return removedGutter
        case .context: return contextGutter
        case .empty: return emptyGutter
        }
    }

    /// 左侧强调色条。
    public static func bar(_ kind: Kind) -> Color {
        switch kind {
        case .added: return OMColors.diffAdded
        case .removed: return OMColors.diffRemoved
        case .context, .empty: return .clear
        }
    }

    private static let addedBackground = dynamic(light: (0.878, 0.965, 0.894), dark: (0.110, 0.220, 0.145))
    private static let addedGutter = dynamic(light: (0.780, 0.929, 0.812), dark: (0.133, 0.310, 0.188))
    private static let removedBackground = dynamic(light: (0.992, 0.894, 0.894), dark: (0.290, 0.130, 0.140))
    private static let removedGutter = dynamic(light: (0.980, 0.804, 0.808), dark: (0.400, 0.165, 0.175))
    private static let contextBackground = dynamic(light: (1, 1, 1), dark: (0.118, 0.122, 0.133))
    private static let contextGutter = dynamic(light: (0.957, 0.961, 0.969), dark: (0.153, 0.157, 0.173))
    private static let emptyBackground = dynamic(light: (0.965, 0.969, 0.976), dark: (0.140, 0.144, 0.158))
    private static let emptyGutter = dynamic(light: (0.945, 0.949, 0.957), dark: (0.153, 0.157, 0.173))
}

/// 字体缩放(由外观设置写入;只在主线程的界面刷新周期读取)。
public enum OMScale {
    nonisolated(unsafe) public static var ui: CGFloat = 1
    nonisolated(unsafe) public static var timeline: CGFloat = 1
}

/// 字体令牌:随「界面字号」缩放;`reading*` 额外乘以「时间线字号」。
public enum OMFonts {
    public static var body: Font { .system(size: 13.5 * OMScale.ui) }
    public static var small: Font { .system(size: 11.5 * OMScale.ui) }
    public static var caption: Font { .system(size: 11 * OMScale.ui) }
    public static var title: Font { .system(size: 15 * OMScale.ui, weight: .semibold) }
    public static var mono: Font { .system(size: 12.5 * OMScale.ui, design: .monospaced) }
    public static var monoSmall: Font { .system(size: 11.5 * OMScale.ui, design: .monospaced) }
    /// 设置页分组标题(与 `title` 同族,略小,半粗)。
    public static var sectionTitle: Font { .system(size: 13 * OMScale.ui, weight: .semibold) }
    /// 受控的自定义字号(随界面字号缩放):仅用于令牌表覆盖不到的特例(Markdown 标题、徽标数字等)。
    /// - Parameters:
    ///   - size: 基准字号(未缩放)
    ///   - weight: 字重
    ///   - design: 字体设计
    public static func custom(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * OMScale.ui, weight: weight, design: design)
    }
    /// 时间线正文
    public static var reading: Font { .system(size: 13.5 * OMScale.ui * OMScale.timeline) }
    /// 时间线代码
    public static var readingMono: Font { .system(size: 12.5 * OMScale.ui * OMScale.timeline, design: .monospaced) }
}
