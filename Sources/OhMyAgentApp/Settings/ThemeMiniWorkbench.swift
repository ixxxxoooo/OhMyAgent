// @author ixxxxoooo
// 主题预览:用指定主题的调色板直接绘制一个「迷你工作台」(侧栏会话列表、对话气泡、代码块、输入框、终端),
// 不依赖当前生效的主题令牌,因此可以在主题列表里同时预览所有主题。

import DesignSystem
import SwiftUI

/// 迷你工作台预览。尺寸按所给 frame 等比绘制(只用形状,不含文字)。
struct ThemeMiniWorkbench: View {
    let package: ThemePackage
    /// 是否绘制终端条与输入框等细节(缩略图可关闭)
    var detailed = true

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            if let palette = package.palette {
                canvas(palette: palette, w: w, h: h)
            } else {
                systemCanvas(w: w, h: h)
            }
        }
    }

    // MARK: 系统主题

    private func systemCanvas(w: CGFloat, h: CGFloat) -> some View {
        HStack(spacing: 0) {
            OMColors.systemSidebar.frame(width: w * 0.26)
            OMColors.systemContentBackground
        }
        .overlay(Image.om("monitor", size: 16).foregroundStyle(OMColors.tertiaryText))
    }

    // MARK: 调色板绘制

    private func canvas(palette: ThemePalette, w: CGFloat, h: CGFloat) -> some View {
        let radius = max(2, palette.style.radiusSet?.control ?? 5 * palette.style.cornerScale)
        let stroke = palette.hairline.color
        let sidebar = (palette.sidebarBackground ?? palette.surface).color
        let ink = palette.editorForeground.color
        let terminalHeight = detailed ? h * 0.2 : 0
        return ZStack(alignment: .topLeading) {
            palette.surface.color
            HStack(spacing: 0) {
                // 侧栏:项目条 + 会话行(运行中/等待/未读状态点)
                VStack(alignment: .leading, spacing: h * 0.045) {
                    Capsule().fill(ink.opacity(0.55)).frame(width: w * 0.13, height: max(2, h * 0.025))
                    sessionRow(palette, dot: palette.accent.color, selected: true, w: w, h: h, radius: radius)
                    sessionRow(palette, dot: palette.warning.color, selected: false, w: w, h: h, radius: radius)
                    sessionRow(palette, dot: palette.success.color, selected: false, w: w, h: h, radius: radius)
                    Spacer(minLength: 0)
                }
                .padding(w * 0.03)
                .frame(width: w * 0.27, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(sidebar)
                .overlay(alignment: .trailing) { Rectangle().fill(stroke).frame(width: 0.5) }

                // 内容区:用户气泡 + 回复 + 代码块 + 输入框
                VStack(alignment: .leading, spacing: h * 0.04) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(palette.card.color)
                        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 0.5))
                        .frame(width: w * 0.34, height: h * 0.1)
                    HStack(spacing: w * 0.012) {
                        Image.om("sparkles", size: max(6, h * 0.05)).foregroundStyle(palette.accent.color)
                        Capsule().fill(ink.opacity(0.7)).frame(width: w * 0.3, height: max(2, h * 0.022))
                    }
                    Capsule().fill(palette.comment.color.opacity(0.7)).frame(width: w * 0.22, height: max(2, h * 0.022))
                    codeBlock(palette, w: w, h: h, radius: radius)
                    Spacer(minLength: 0)
                    if detailed {
                        RoundedRectangle(cornerRadius: radius * 1.6, style: .continuous)
                            .fill(palette.card.color)
                            .overlay(RoundedRectangle(cornerRadius: radius * 1.6, style: .continuous).strokeBorder(stroke, lineWidth: 0.5))
                            .overlay(alignment: .trailing) {
                                Circle().fill(palette.accent.color).frame(width: h * 0.07, height: h * 0.07).padding(.trailing, w * 0.012)
                            }
                            .frame(height: h * 0.11)
                    }
                }
                .padding(w * 0.03)
                .padding(.bottom, terminalHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if detailed { terminal(palette, w: w, h: h, height: terminalHeight, stroke: stroke) }
        }
        .clipped()
    }

    private func sessionRow(_ palette: ThemePalette, dot: Color, selected: Bool, w: CGFloat, h: CGFloat, radius: CGFloat) -> some View {
        HStack(spacing: w * 0.012) {
            Circle().fill(dot).frame(width: max(3, h * 0.04), height: max(3, h * 0.04))
            Capsule().fill(palette.editorForeground.color.opacity(selected ? 0.75 : 0.4)).frame(width: w * 0.11, height: max(2, h * 0.022))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, w * 0.01)
        .frame(height: h * 0.075)
        .background(selected ? palette.accent.color.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: radius * 0.7, style: .continuous))
    }

    /// 代码块:编辑器底色 + 用语法色画的几行「代码」。
    private func codeBlock(_ palette: ThemePalette, w: CGFloat, h: CGFloat, radius: CGFloat) -> some View {
        let unit = max(2, h * 0.022)
        return VStack(alignment: .leading, spacing: h * 0.03) {
            HStack(spacing: w * 0.01) {
                Capsule().fill(palette.keyword.color).frame(width: w * 0.06, height: unit)
                Capsule().fill(palette.function.color).frame(width: w * 0.1, height: unit)
                Capsule().fill(palette.editorForeground.color.opacity(0.6)).frame(width: w * 0.05, height: unit)
            }
            HStack(spacing: w * 0.01) {
                Capsule().fill(palette.type.color).frame(width: w * 0.07, height: unit)
                Capsule().fill(palette.property.color).frame(width: w * 0.08, height: unit)
                Capsule().fill(palette.string.color).frame(width: w * 0.12, height: unit)
            }
            HStack(spacing: w * 0.01) {
                Capsule().fill(palette.comment.color).frame(width: w * 0.16, height: unit)
                Capsule().fill(palette.number.color).frame(width: w * 0.04, height: unit)
            }
        }
        .padding(w * 0.02)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.editorBackground.color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.hairline.color, lineWidth: 0.5))
    }

    /// 底部终端条:用主题的 ANSI 色画一行提示符与输出。
    private func terminal(_ palette: ThemePalette, w: CGFloat, h: CGFloat, height: CGFloat, stroke: Color) -> some View {
        let ansi = palette.ansiColors
        let unit = max(2, h * 0.022)
        return VStack {
            Spacer(minLength: 0)
            HStack(spacing: w * 0.01) {
                Capsule().fill(ansi[2].color).frame(width: w * 0.04, height: unit)
                Capsule().fill(ansi[4].color).frame(width: w * 0.08, height: unit)
                Capsule().fill(palette.editorForeground.color.opacity(0.7)).frame(width: w * 0.12, height: unit)
                Capsule().fill(ansi[1].color).frame(width: w * 0.05, height: unit)
                Capsule().fill(ansi[3].color).frame(width: w * 0.06, height: unit)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, w * 0.03)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(palette.editorBackground.color)
            .overlay(alignment: .top) { Rectangle().fill(stroke).frame(height: 0.5) }
        }
    }
}
