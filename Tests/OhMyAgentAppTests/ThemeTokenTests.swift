// @author ixxxxoooo
// 主题令牌:全部主题的派生令牌完整性(ANSI、对比度、描边、状态色)与变更追踪。

import AppKit
import DesignSystem
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("主题令牌", .serialized)
struct ThemeTokenTests {
    /// WCAG 对比度(sRGB 线性化后的相对亮度)。
    private func contrast(_ a: ThemeRGB, _ b: ThemeRGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func lum(_ c: ThemeRGB) -> Double { 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue) }
        let la = lum(a), lb = lum(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test("每个主题都有 16 个 ANSI 色,且前 8 个互不相同")
    func ansiPalette() {
        for package in ThemePackage.all {
            guard let palette = package.palette else { continue }
            let colors = palette.ansiColors
            #expect(colors.count == 16, "\(package.id) ANSI 色数量")
            #expect(Set(colors.prefix(8).map(\.hexString)).count == 8, "\(package.id) 前 8 色应互不相同")
        }
    }

    @Test("正文/次要文字相对底色有足够对比度,三级文字比次要更淡")
    func textContrast() {
        for package in ThemePackage.all {
            guard let palette = package.palette else { continue }
            #expect(contrast(palette.foreground, palette.surface) >= 7, "\(package.id) 正文对比度 \(contrast(palette.foreground, palette.surface))")
            #expect(contrast(palette.secondaryText, palette.surface) >= 3, "\(package.id) 次要文字对比度 \(contrast(palette.secondaryText, palette.surface))")
            #expect(contrast(palette.tertiaryText, palette.surface) < contrast(palette.secondaryText, palette.surface), "\(package.id) 三级文字应更淡")
            #expect(palette.hairline != palette.surface, "\(package.id) 分隔线应可见")
        }
    }

    @Test("强调色在底色上可辨(对比度 ≥ 2)")
    func accentVisible() {
        for package in ThemePackage.all {
            guard let palette = package.palette else { continue }
            #expect(contrast(palette.accent, palette.surface) >= 2, "\(package.id) 强调色对比度 \(contrast(palette.accent, palette.surface))")
            #expect(contrast(palette.warning, palette.surface) >= 2, "\(package.id) 警示色对比度 \(contrast(palette.warning, palette.surface))")
        }
    }

    @Test("主题变更会递增追踪器修订号(令牌读取方据此刷新)")
    func trackerBump() {
        let before = ThemeTracker.shared.revision
        ThemeRuntime.bump()
        #expect(ThemeTracker.shared.revision == before + 1)
    }

    @Test("主题风格:圆角倍率影响尺寸令牌,系统主题为标准风格")
    func styleScale() {
        let saved = ThemeRuntime.package
        defer { ThemeRuntime.package = saved }
        ThemeRuntime.package = .system
        let base = OMMetrics.cardRadius
        #expect(ThemeRuntime.style == .standard)
        var round = ThemePalette.make(.darkBase) { $0.style = ThemeStyle(cornerScale: 1.5) }
        round.style.cornerScale = 1.5
        ThemeRuntime.package = ThemePackage(id: "t", name: "t", group: .system, tone: .dark, palette: round)
        #expect(OMMetrics.cardRadius == base * 1.5)
    }
}
