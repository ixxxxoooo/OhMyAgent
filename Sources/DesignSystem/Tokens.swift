// @author ixxxxoooo
// 设计令牌:颜色、尺寸、字体。全部使用系统语义色以适配深浅色与高对比度。

import AppKit
import SwiftUI

/// 尺寸令牌:圆角随主题风格(`ThemeStyle.cornerScale`)缩放。
public enum OMMetrics {
    public static var cardRadius: CGFloat { 12 * CGFloat(ThemeRuntime.style.cornerScale) }
    public static var controlRadius: CGFloat { 8 * CGFloat(ThemeRuntime.style.cornerScale) }
    public static let sidebarWidth: CGFloat = 248
    public static let toolbarHeight: CGFloat = 44
    public static let timelineMaxWidth: CGFloat = 820
    public static let spacing: CGFloat = 12
    /// 文件类型图标尺寸:内联在文字/chip/工具行文件名前
    public static let fileIconInline: CGFloat = 14
    /// 文件类型图标尺寸:列表行(资源管理器、搜索结果),与 11.5pt 小字相配,不再偏大
    public static let fileIconList: CGFloat = 14
}

/// 颜色令牌。系统主题下使用系统语义色;选择主题包后,**所有**颜色按调色板取色(无公共例外)。
public enum OMColors {
    /// 按当前明暗在两组颜色间切换的动态颜色(系统主题回退用)。
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// 当前是否偏深色:主题包按调色板判断,系统主题交给动态颜色处理(这里返回 nil)。
    private static var paletteIsDark: Bool? { ThemeRuntime.palette?.isDark }

    /// 时间线与编辑区背景(纯色)
    /// 系统主题:浅色 #F6F6F7(见 AGENTS.md「界面配色」)。
    public static var surface: Color {
        ThemeRuntime.palette.map { $0.surface.color } ?? contentBackground
    }
    /// 系统主题的内容区背景:浅色 #F6F6F7、深色 #1E1F22。
    public static var contentBackground: Color { systemContentBackground }
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
        return dynamic(light: NSColor(srgbRed: 0.975, green: 0.977, blue: 0.985, alpha: 1),
                       dark: NSColor(srgbRed: 0.145, green: 0.150, blue: 0.165, alpha: 1))
    }
    /// 玻璃回退时的不透明 chrome 背景(主题包取卡片色,系统主题取窗口背景)
    public static var opaqueChrome: Color {
        ThemeRuntime.palette.map { $0.card.color } ?? Color(nsColor: .windowBackgroundColor)
    }
    /// 正文前景(主文字、悬停/选中时的文字):主题包取前景色,系统取 labelColor。
    public static var primaryText: Color {
        ThemeRuntime.palette.map { $0.foreground.color } ?? Color(nsColor: .labelColor)
    }
    /// 分隔线(描边强度随主题风格)
    public static var hairline: Color {
        ThemeRuntime.palette.map { $0.hairline.color } ?? Color(nsColor: .separatorColor)
    }
    public static var secondaryText: Color {
        ThemeRuntime.palette.map { $0.secondaryText.color } ?? Color(nsColor: .secondaryLabelColor)
    }
    public static var tertiaryText: Color {
        ThemeRuntime.palette.map { $0.tertiaryText.color } ?? Color(nsColor: .tertiaryLabelColor)
    }
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
    public static var onAccent: Color { Color.white }
    /// 主强调色:用户选择 > 主题默认 > 系统强调色。
    public static var accent: Color { ThemeRuntime.accent?.color ?? Color.accentColor }
    /// 第二强调色:链接、次要徽标;未指定时回退主强调色。
    public static var accent2: Color { ThemeRuntime.accent2?.color ?? accent }

    // MARK: 交互填充

    /// 极轻填充(斑马纹、代码框底):随主题前景 4%。
    public static var subtleFill: Color { primaryText.opacity(0.04 * ThemeRuntime.style.fillScale) }
    /// 悬停填充:随主题前景 7%。
    public static var hoverFill: Color { primaryText.opacity(0.07 * ThemeRuntime.style.fillScale) }
    /// 选中填充:强调色 14%(让每个主题的选中态有自己的色相)。
    public static var selectedFill: Color { accent.opacity(0.14 * ThemeRuntime.style.fillScale) }
    /// 按压/强悬停填充:随主题前景 12%。
    public static var pressedFill: Color { primaryText.opacity(0.12 * ThemeRuntime.style.fillScale) }

    // MARK: 状态色(运行星芒、托盘闪烁点、会话状态点、项目状态标识共用)

    /// 运行中。
    public static var statusRunning: Color { accent }
    /// 等待处理(权限/提问)。
    public static var statusWaiting: Color { warning }
    /// 已完成未读。
    public static var statusUnread: Color { success }
    /// 空闲。
    public static var statusIdle: Color { tertiaryText }

    // MARK: 遮罩与阴影

    /// 全窗遮罩(搜索窗等模态浮层背后):随主题明暗。
    public static var scrim: Color {
        let dark = paletteIsDark
        if let dark { return Color.black.opacity(dark ? 0.46 : 0.26) }
        return dynamic(light: NSColor(white: 0, alpha: 0.26), dark: NSColor(white: 0, alpha: 0.46))
    }
    /// 分类色板(图表、Git 图谱泳道、用量分类):取自主题语义色与语法色,系统主题用系统色。
    public static func chart(_ index: Int) -> Color {
        let count = 8
        let i = ((index % count) + count) % count
        if let palette = ThemeRuntime.palette {
            let list = [ThemeRuntime.accent ?? palette.accent, palette.accent2, palette.success, palette.warning, palette.keyword, palette.type, palette.danger, palette.function]
            return list[i].color
        }
        let list: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal, .systemRed, .systemIndigo]
        return Color(nsColor: list[i])
    }
    /// 阴影基色(不透明度由 `omShadow` 按档位与主题风格决定)。
    public static var shadowInk: Color { Color.black }
    /// 蒙版用不透明色(渐变淡出、`mask`):只看 alpha,颜色无意义。
    public static var maskInk: Color { Color.black }
}

/// 终端配色:全部取自主题调色板(系统主题取系统语义色),与编辑器/界面保持一致。
public enum OMTerminalPalette {
    /// 终端背景
    public static var background: NSColor {
        if let palette = ThemeRuntime.palette { return palette.editorBackground.nsColor }
        return currentIsDark
            ? NSColor(srgbRed: 0.118, green: 0.122, blue: 0.133, alpha: 1)
            : NSColor(srgbRed: 0xF6 / 255, green: 0xF6 / 255, blue: 0xF7 / 255, alpha: 1)
    }
    /// 终端前景
    public static var foreground: NSColor {
        if let palette = ThemeRuntime.palette { return palette.editorForeground.nsColor }
        return currentIsDark ? NSColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    }
    /// 光标色
    public static var cursor: NSColor {
        ThemeRuntime.accent.map { $0.nsColor } ?? NSColor.controlAccentColor
    }
    /// 选区底色
    public static var selection: NSColor {
        (ThemeRuntime.accent?.nsColor ?? NSColor.controlAccentColor).withAlphaComponent(0.30)
    }
    /// 当前是否深色:主题包按调色板,系统主题按应用的有效外观。
    public static var currentIsDark: Bool {
        if let palette = ThemeRuntime.palette { return palette.isDark }
        return ThemeRuntime.systemIsDark
    }
    /// ANSI 16 色(系统主题按当前明暗选 xterm 风格色板)。
    public static func ansi(dark: Bool) -> [NSColor] {
        if let palette = ThemeRuntime.palette { return palette.ansiColors.map(\.nsColor) }
        let hex: [UInt32] = dark
            ? [0x1E1F22, 0xFF6B6B, 0x4CC38A, 0xF0A04B, 0x66A6FC, 0xFC5EA3, 0x5CCCD9, 0xDCDEE3,
               0x73787F, 0xFF8A8A, 0x6FE0A8, 0xF5BB7A, 0x8CBEFF, 0xFF85BC, 0x85E3EE, 0xFFFFFF]
            : [0x1A1A1F, 0xCF222E, 0x1A7F37, 0xB25E09, 0x3B579E, 0xAD1F8C, 0x1C6E85, 0xC8CAD0,
               0x6B7885, 0xE5484D, 0x2DA44E, 0xD08A2E, 0x0A6CFF, 0xC93FA8, 0x2196AD, 0xFFFFFF]
        return hex.map { ThemeRGB(hex: $0).nsColor }
    }
}

public extension View {
    /// 卡片级阴影(单层令牌):强度随主题风格;所有悬浮卡片统一使用,不再各自叠阴影。
    func omCardShadow() -> some View {
        shadow(color: OMColors.shadowInk.opacity(0.14 * ThemeRuntime.style.shadowScale), radius: 12, y: 4)
    }

    /// 浮层级阴影(搜索窗、悬浮窗等大块浮层)。
    func omFloatShadow() -> some View {
        shadow(color: OMColors.shadowInk.opacity(0.24 * ThemeRuntime.style.shadowScale), radius: 28, y: 10)
    }
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
