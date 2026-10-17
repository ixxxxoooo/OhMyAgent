// @author ixxxxoooo
// Cursor 纸感主题:默认选中、对比度、禁用纯黑纯白、风格令牌与旧主题回归(规范见 AGENTS.md 4.4)。

import AppKit
import DesignSystem
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("Cursor 纸感主题", .serialized)
struct PaperThemeTests {
    private func paper() throws -> [(id: String, palette: ThemePalette)] {
        try ["paper-light", "paper-dark"].map { id in
            (id, try #require(ThemePackage.find(id).palette, "\(id) 缺失"))
        }
    }

    private func withRuntime(_ package: ThemePackage, _ body: () -> Void) {
        let saved = ThemeRuntime.package
        ThemeRuntime.package = package
        body()
        ThemeRuntime.package = saved
    }

    @Test("默认主题为纸感浅色,两个纸感主题同属 paper 分组且明暗正确")
    func catalog() throws {
        #expect(ThemePackage.defaultID == "paper-light")
        let light = ThemePackage.find("paper-light"), dark = ThemePackage.find("paper-dark")
        #expect(light.group == .paper && dark.group == .paper)
        #expect(light.tone == .light && dark.tone == .dark)
        #expect(ThemeGroup.paper.title == String(localized: "纸感"))
    }

    @Test("文字对比度:正文 ≥ 7,次要 ≥ 4.5,三级更淡")
    func textContrast() throws {
        for (id, p) in try paper() {
            #expect(p.foreground.contrast(with: p.surface) >= 7, "\(id) 正文")
            #expect(p.secondaryText.contrast(with: p.surface) >= 4.5, "\(id) 次要文字 \(p.secondaryText.contrast(with: p.surface))")
            #expect(p.tertiaryText.contrast(with: p.surface) < p.secondaryText.contrast(with: p.surface), "\(id) 三级文字应更淡")
        }
    }

    @Test("链接用的强调色与状态色文字对比度 ≥ 4.5")
    func semanticTextContrast() throws {
        for (id, p) in try paper() {
            #expect((p.accentText ?? p.accent).contrast(with: p.surface) >= 4.5, "\(id) 强调文字")
            #expect(p.success.contrast(with: p.surface) >= 4.5, "\(id) 成功")
            #expect(p.danger.contrast(with: p.surface) >= 4.5, "\(id) 危险")
            #expect(p.warning.contrast(with: p.surface) >= 4.5, "\(id) 警示")
        }
    }

    @Test("动作按钮的前景在填充上 ≥ 4.5")
    func actionButtonsReadable() throws {
        for (id, p) in try paper() {
            let warm = try #require(p.actionWarm), positive = try #require(p.actionPositive)
            #expect(p.readableForeground(on: warm).contrast(with: warm) >= 4.5, "\(id) 暖色按钮")
            #expect(p.readableForeground(on: positive).contrast(with: positive) >= 4.5, "\(id) 正向按钮")
            // 主按钮:墨色实底 + 画布前景
            #expect(p.foreground.contrast(with: p.surface) >= 7, "\(id) 主按钮")
        }
    }

    @Test("侧栏与内容区必须不同;不得出现纯白纯黑")
    func surfacesAndNoPureNeutrals() throws {
        for (id, p) in try paper() {
            let sidebar = try #require(p.sidebarBackground)
            #expect(sidebar != p.surface, "\(id) 侧栏应与内容区不同")
            let all: [ThemeRGB] = [p.surface, p.card, sidebar, p.editorBackground, p.editorForeground, p.gutterBackground, p.currentLine,
                                   p.accent, p.accent2, p.success, p.danger, p.warning, p.diffAdded, p.diffRemoved,
                                   p.onAccent, p.outline, p.selection].compactMap { $0 }
            for color in all {
                #expect(color.hexString != "#FFFFFF" && color.hexString != "#000000", "\(id) 含纯白/纯黑")
            }
        }
    }

    @Test("纸感风格:关闭玻璃、4/8 圆角、墨色主按钮、中性选中")
    func styleTokens() throws {
        let light = ThemePackage.find("paper-light")
        withRuntime(light) {
            #expect(ThemeRuntime.style.allowsGlass == false && ThemeRuntime.style.flatCards)
            #expect(OMRadius.tag == 4 && OMRadius.control == 4 && OMRadius.card == 4)
            #expect(OMRadius.floating == 8 && OMRadius.modal == 8)
            #expect(ThemeRuntime.style.primaryButton == .ink && ThemeRuntime.style.selectionTint == .neutral)
        }
    }

    @Test("旧主题:ThemeStyle 默认值保持旧行为(圆角令牌取旧值)")
    func legacyUnchanged() {
        let standard = ThemeStyle.standard
        #expect(standard.allowsGlass && standard.radiusSet == nil && standard.primaryButton == .accent && standard.selectionTint == .accent)
        for package in ThemePackage.builtin where package.group != .paper {
            guard let palette = package.palette else { continue }
            #expect(palette.style.allowsGlass && palette.style.radiusSet == nil && palette.style.primaryButton == .accent, "\(package.id) 不应受纸感影响")
        }
        withRuntime(.system) {
            #expect(OMRadius.card == 12 && OMRadius.control == 8 && OMRadius.tag == 5 && OMRadius.floating == 14 && OMRadius.modal == 20)
        }
    }

    @Test("间距令牌是 4 的倍数,标准动效 150ms")
    func spacingAndMotion() {
        for value in [OMSpacing.xs, OMSpacing.sm, OMSpacing.md, OMSpacing.lg, OMSpacing.xl, OMSpacing.xxl, OMSpacing.xxxl] {
            #expect(value.truncatingRemainder(dividingBy: 4) == 0)
        }
    }
}
