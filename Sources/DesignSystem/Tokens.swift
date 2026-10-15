// @author ygw
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
}

/// 颜色令牌。
public enum OMColors {
    /// 时间线与编辑区背景(纯色)
    public static let surface = Color(nsColor: .textBackgroundColor)
    /// 卡片背景(纯色)
    public static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.145, green: 0.150, blue: 0.165, alpha: 1)
            : NSColor(srgbRed: 0.975, green: 0.977, blue: 0.985, alpha: 1)
    })
    /// 玻璃回退时的不透明 chrome 背景
    public static let opaqueChrome = Color(nsColor: .windowBackgroundColor)
    /// 分隔线
    public static let hairline = Color(nsColor: .separatorColor)
    public static let secondaryText = Color(nsColor: .secondaryLabelColor)
    public static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    public static let diffAdded = Color(nsColor: .systemGreen)
    public static let diffRemoved = Color(nsColor: .systemRed)
    public static let warning = Color(nsColor: .systemOrange)
    public static let accent = Color.accentColor
}

/// 字体令牌。
public enum OMFonts {
    public static let body = Font.system(size: 13.5)
    public static let small = Font.system(size: 11.5)
    public static let caption = Font.system(size: 11)
    public static let title = Font.system(size: 15, weight: .semibold)
    public static let mono = Font.system(size: 12.5, design: .monospaced)
    public static let monoSmall = Font.system(size: 11.5, design: .monospaced)
}
