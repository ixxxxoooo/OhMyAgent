// @author ixxxxoooo
// 已解析令牌表测试:缓存值与「未缓存参考实现」逐项相等(所有内置主题、强调色覆盖、明暗两种外观),
// 同一主题下重复读取不重建,主题切换/覆盖变化后立即失效。

import AppKit
import SwiftUI
import Testing

@testable import DesignSystem

@MainActor
@Suite("已解析令牌表", .serialized)
struct ResolvedTokensTests {
    /// 全部缓存令牌:名称、缓存读取、参考实现读取。
    private static let tokens: [(String, () -> Color, () -> Color)] = [
        ("surface", { OMColors.surface }, { OMColorsUncached.surface }),
        ("sidebar", { OMColors.sidebar }, { OMColorsUncached.sidebar }),
        ("card", { OMColors.card }, { OMColorsUncached.card }),
        ("opaqueChrome", { OMColors.opaqueChrome }, { OMColorsUncached.opaqueChrome }),
        ("primaryText", { OMColors.primaryText }, { OMColorsUncached.primaryText }),
        ("hairline", { OMColors.hairline }, { OMColorsUncached.hairline }),
        ("secondaryText", { OMColors.secondaryText }, { OMColorsUncached.secondaryText }),
        ("tertiaryText", { OMColors.tertiaryText }, { OMColorsUncached.tertiaryText }),
        ("diffAdded", { OMColors.diffAdded }, { OMColorsUncached.diffAdded }),
        ("diffRemoved", { OMColors.diffRemoved }, { OMColorsUncached.diffRemoved }),
        ("warning", { OMColors.warning }, { OMColorsUncached.warning }),
        ("success", { OMColors.success }, { OMColorsUncached.success }),
        ("danger", { OMColors.danger }, { OMColorsUncached.danger }),
        ("onAccent", { OMColors.onAccent }, { OMColorsUncached.onAccent }),
        ("accentText", { OMColors.accentText }, { OMColorsUncached.accentText }),
        ("link", { OMColors.link }, { OMColorsUncached.link }),
        ("actionFill", { OMColors.actionFill }, { OMColorsUncached.actionFill }),
        ("onAction", { OMColors.onAction }, { OMColorsUncached.onAction }),
        ("actionWarm", { OMColors.actionWarm }, { OMColorsUncached.actionWarm }),
        ("onWarm", { OMColors.onWarm }, { OMColorsUncached.onWarm }),
        ("actionPositive", { OMColors.actionPositive }, { OMColorsUncached.actionPositive }),
        ("onPositive", { OMColors.onPositive }, { OMColorsUncached.onPositive }),
        ("outline", { OMColors.outline }, { OMColorsUncached.outline }),
        ("accent", { OMColors.accent }, { OMColorsUncached.accent }),
        ("accent2", { OMColors.accent2 }, { OMColorsUncached.accent2 }),
        ("scrollThumb", { OMColors.scrollThumb }, { OMColorsUncached.scrollThumb }),
        ("scrollThumbActive", { OMColors.scrollThumbActive }, { OMColorsUncached.scrollThumbActive }),
        ("subtleFill", { OMColors.subtleFill }, { OMColorsUncached.subtleFill }),
        ("hoverFill", { OMColors.hoverFill }, { OMColorsUncached.hoverFill }),
        ("selectedFill", { OMColors.selectedFill }, { OMColorsUncached.selectedFill }),
        ("pressedFill", { OMColors.pressedFill }, { OMColorsUncached.pressedFill }),
        ("statusActive", { OMColors.statusActive }, { OMColorsUncached.statusActive }),
        ("statusRunning", { OMColors.statusRunning }, { OMColorsUncached.statusRunning }),
        ("statusWaiting", { OMColors.statusWaiting }, { OMColorsUncached.statusWaiting }),
        ("statusUnread", { OMColors.statusUnread }, { OMColorsUncached.statusUnread }),
        ("statusIdle", { OMColors.statusIdle }, { OMColorsUncached.statusIdle }),
        ("scrim", { OMColors.scrim }, { OMColorsUncached.scrim })
    ]

    /// 把颜色在指定外观下解析成 sRGB 分量(动态系统色每次新建实例,只能比较解析后的数值)。
    private func rgba(_ color: Color, _ name: NSAppearance.Name) -> [Double] {
        var out: [Double] = []
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            out = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Double($0) }
        }
        return out
    }

    private func expectSame(_ context: String) {
        for (name, cached, reference) in Self.tokens {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let a = rgba(cached(), appearance), b = rgba(reference(), appearance)
                #expect(a.count == 4 && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }, "\(context) · \(name) · \(appearance.rawValue): \(a) ≠ \(b)")
            }
        }
        for index in -2..<10 {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let a = rgba(OMColors.chart(index), appearance), b = rgba(OMColorsUncached.chart(((index % 8) + 8) % 8), appearance)
                #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }, "\(context) · chart(\(index))")
            }
        }
    }

    @Test("所有内置主题:缓存令牌与未缓存参考实现逐项相等")
    func matchesReferenceForEveryTheme() {
        let saved = ThemeRuntime.package
        defer { ThemeRuntime.package = saved }
        for package in ThemePackage.all + [ThemePackage.system] {
            ThemeRuntime.package = package
            expectSame(package.id)
        }
    }

    @Test("强调色覆盖:设置与清除后立即生效且与参考一致")
    func accentOverrideInvalidates() {
        let savedPackage = ThemeRuntime.package, savedAccent = ThemeRuntime.accentOverride, savedAccent2 = ThemeRuntime.accent2Override
        defer { ThemeRuntime.package = savedPackage; ThemeRuntime.accentOverride = savedAccent; ThemeRuntime.accent2Override = savedAccent2 }
        for package in [ThemePackage.system, ThemePackage.find(ThemePackage.defaultID)] {
            ThemeRuntime.package = package
            ThemeRuntime.accentOverride = nil
            ThemeRuntime.accent2Override = nil
            let before = rgba(OMColors.accent, .aqua)
            ThemeRuntime.accentOverride = ThemeRGB(hex: 0x12AB34)
            ThemeRuntime.accent2Override = ThemeRGB(hex: 0xAB1234)
            expectSame("\(package.id) + 覆盖")
            #expect(rgba(OMColors.accent, .aqua) != before)
            #expect(rgba(OMColors.link, .aqua) != before)
            ThemeRuntime.accentOverride = nil
            ThemeRuntime.accent2Override = nil
            expectSame("\(package.id) 清除覆盖")
            #expect(rgba(OMColors.accent, .aqua) == before)
        }
    }

    @Test("同一主题下重复读取不重建缓存;主题切换只重建一次")
    func rebuildsOnlyOnChange() {
        let saved = ThemeRuntime.package
        defer { ThemeRuntime.package = saved }
        ThemeRuntime.package = .system
        _ = OMColors.surface
        let base = ResolvedTokens.rebuildCount
        for _ in 0..<2000 { _ = OMColors.hairline; _ = OMColors.secondaryText; _ = OMColors.selectedFill; _ = OMColors.chart(3) }
        #expect(ResolvedTokens.rebuildCount == base)
        ThemeRuntime.package = ThemePackage.find(ThemePackage.defaultID)
        _ = OMColors.surface
        _ = OMColors.hairline
        #expect(ResolvedTokens.rebuildCount == base + 1)
        ThemeRuntime.bump()
        _ = OMColors.surface
        #expect(ResolvedTokens.rebuildCount == base + 2)
    }

    @Test("系统主题:动态色在缓存中是同一实例(不再每次新建)")
    func systemDynamicColorsAreStable() {
        let saved = ThemeRuntime.package
        defer { ThemeRuntime.package = saved }
        ThemeRuntime.package = .system
        #expect(OMColors.scrim == OMColors.scrim)
        #expect(OMColors.card == OMColors.card)
    }
}
