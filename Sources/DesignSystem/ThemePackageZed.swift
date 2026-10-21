// @author ixxxxoooo
// Zed 风格主题:取自 zed.dev 与 Zed 编辑器默认的 One Dark / One Light 配色。
// 特征:平面卡片 + 1px 细描边、无玻璃、小圆角、冷灰蓝底色、蓝色强调。

import Foundation

extension ThemeRadiusSet {
    /// Zed:控件 4、卡片/轻浮层 6、模态 8,比纸感略圆、远小于玻璃主题。
    public static let zed = ThemeRadiusSet(tag: 3, control: 4, card: 6, floating: 6, modal: 8)
}

extension ThemeStyle {
    /// Zed 风格:不透明平面卡片,细描边,弱阴影,强调色填充主按钮。
    static let zed = ThemeStyle(strokeScale: 1.0, shadowScale: 0.5, fillScale: 1.0, allowsGlass: false,
                                radiusSet: .zed, primaryButton: .accent, selectionTint: .accent, flatCards: true)
}

extension ThemePackage {
    /// Zed One Dark:编辑区 #282C34,面板/侧栏 #2F343E,描边 #464B57,强调 #74ADE8。
    static let zedDark = ThemePackage(id: "zed-dark", name: String(localized: "Zed 深色"), group: .zed, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x282C34, card: 0x2F343E, gutter: 0x282C34, currentLine: 0x2C313A, sidebar: 0x21252B)
        $0.editorForeground = ThemeRGB(hex: 0xDCE0E5); $0.gutterForeground = ThemeRGB(hex: 0x636D83)
        $0.accent = ThemeRGB(hex: 0x74ADE8); $0.accent2 = ThemeRGB(hex: 0xB477CF)
        $0.accentText = ThemeRGB(hex: 0x74ADE8)
        $0.success = ThemeRGB(hex: 0xA1C181); $0.danger = ThemeRGB(hex: 0xD07277); $0.warning = ThemeRGB(hex: 0xDEC184)
        $0.actionWarm = ThemeRGB(hex: 0xB8975A); $0.actionPositive = ThemeRGB(hex: 0x6F9A58)
        $0.diffAdded = $0.surface.mixed(with: $0.success, 0.14); $0.diffRemoved = $0.surface.mixed(with: $0.danger, 0.15)
        $0.setSyntax(keyword: 0xB477CF, string: 0xA1C181, comment: 0x5D636F, number: 0xBF956A, type: 0x6EB4BF, function: 0x73ADE9, property: 0xD07277)
        $0.onAccent = ThemeRGB(hex: 0x1B1F27)
        $0.outline = ThemeRGB(hex: 0x464B57)
        $0.selection = ThemeRGB(hex: 0x3B4F70)
        $0.secondaryTextColor = ThemeRGB(hex: 0xA9AFBC); $0.tertiaryTextColor = ThemeRGB(hex: 0x878A98)
        $0.ansi = [0x282C34, 0xD07277, 0xA1C181, 0xDEC184, 0x74ADE8, 0xB477CF, 0x6EB4BF, 0xDCE0E5,
                   0x636D83, 0xDE8C93, 0xB8D49B, 0xE8D3A0, 0x9CC3F0, 0xC79BDC, 0x8FC7D1, 0xF0F2F5].map { ThemeRGB(hex: $0) }
        $0.style = .zed
    })

    /// Zed One Light:编辑区 #FAFAFA,面板/侧栏 #EBEBEC,描边 #C9C9CA,强调 #5C78E2。
    static let zedLight = ThemePackage(id: "zed-light", name: String(localized: "Zed 浅色"), group: .zed, tone: .light, palette: .make(.lightBase) {
        $0.setBackgrounds(surface: 0xFAFAFA, card: 0xF1F1F2, gutter: 0xFAFAFA, currentLine: 0xF0F0F1, sidebar: 0xEBEBEC)
        $0.editorForeground = ThemeRGB(hex: 0x383A41); $0.gutterForeground = ThemeRGB(hex: 0xA2A3A7)
        $0.accent = ThemeRGB(hex: 0x5C78E2); $0.accent2 = ThemeRGB(hex: 0xA449AB)
        $0.accentText = ThemeRGB(hex: 0x3F5BC4)
        $0.success = ThemeRGB(hex: 0x3F8A3E); $0.danger = ThemeRGB(hex: 0xD36151); $0.warning = ThemeRGB(hex: 0x8F6F12)
        $0.actionWarm = ThemeRGB(hex: 0xB8862B); $0.actionPositive = ThemeRGB(hex: 0x3F8A3E)
        $0.diffAdded = $0.surface.mixed(with: $0.success, 0.14); $0.diffRemoved = $0.surface.mixed(with: $0.danger, 0.13)
        $0.setSyntax(keyword: 0xA449AB, string: 0x50A14F, comment: 0xA2A3A7, number: 0xAD6E25, type: 0x3882B7, function: 0x5B79E3, property: 0xD3604F)
        $0.onAccent = ThemeRGB(hex: 0xFAFAFA)
        $0.outline = ThemeRGB(hex: 0xC9C9CA)
        $0.selection = ThemeRGB(hex: 0xC3CEF5)
        $0.secondaryTextColor = ThemeRGB(hex: 0x5F6168); $0.tertiaryTextColor = ThemeRGB(hex: 0x8C8E95)
        $0.ansi = [0x383A41, 0xD36151, 0x50A14F, 0xA78C32, 0x5C78E2, 0xA449AB, 0x3882B7, 0xDCDCDD,
                   0x7C7E86, 0xDE8478, 0x6FB86E, 0xC4A84A, 0x7F95EA, 0xBB6DC1, 0x5A9CCB, 0xFAFAFA].map { ThemeRGB(hex: $0) }
        $0.style = .zed
    })
}
