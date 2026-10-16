// @author ixxxxoooo
// 主题包:颜色解析、预置主题完整性、运行时强调色优先级、编辑器配色跟随。

import AppKit
import DesignSystem
import EditorKit
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("主题包", .serialized)
struct ThemePackageTests {
    /// 每个用例结束后还原运行时,避免污染其他测试。
    private func withRuntime(_ package: ThemePackage, accent: ThemeRGB? = nil, accent2: ThemeRGB? = nil, _ body: () -> Void) {
        let saved = (ThemeRuntime.package, ThemeRuntime.accentOverride, ThemeRuntime.accent2Override)
        ThemeRuntime.package = package
        ThemeRuntime.accentOverride = accent
        ThemeRuntime.accent2Override = accent2
        body()
        (ThemeRuntime.package, ThemeRuntime.accentOverride, ThemeRuntime.accent2Override) = saved
    }

    @Test("十六进制解析与回写")
    func hex() {
        let rgb = ThemeRGB(hex: 0xD97757)
        #expect(rgb.hexString == "#D97757")
        #expect(ThemeRGB(hexString: "#d97757") == rgb)
        #expect(ThemeRGB(hexString: "D97757") == rgb)
        #expect(ThemeRGB(hexString: "#12345") == nil)
        #expect(ThemeRGB(hexString: "zzzzzz") == nil)
        #expect(ThemeRGB(red: 2, green: -1, blue: 0.5).hexString == "#FF0080")
    }

    @Test("预置主题:id 唯一,含 Cursor/Anthropic/Claude Code 三类,未知 id 回退系统")
    func catalog() {
        let ids = ThemePackage.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("cursor-dark") && ids.contains("anthropic-light") && ids.contains("claude-dark"))
        #expect(ThemePackage.all.filter { $0.group == .claudeCode }.count >= 4)
        #expect(ThemePackage.find("不存在") == .system)
        #expect(ThemePackage.system.palette == nil && ThemePackage.system.tone == .system)
    }

    @Test("非系统主题的明暗倾向与编辑器背景亮度一致")
    func toneMatchesPalette() {
        for package in ThemePackage.all {
            guard let palette = package.palette else { continue }
            #expect((package.tone == .dark) == palette.isDark, "\(package.id) 明暗与调色板不一致")
        }
    }

    @Test("色盲友好主题的增/删不使用红绿")
    func colorblind() throws {
        for id in ["cursor-light-colorblind", "claude-dark-daltonized", "claude-light-daltonized"] {
            let palette = try #require(ThemePackage.find(id).palette)
            // 成功色偏蓝(B 分量 > R 分量),危险色偏橙(R > B)
            #expect(palette.success.blue > palette.success.red, "\(id) 成功色应偏蓝")
            #expect(palette.danger.red > palette.danger.blue, "\(id) 危险色应偏橙")
        }
    }

    @Test("强调色优先级:用户选择 > 主题默认 > 系统")
    func accentPriority() {
        withRuntime(.system) {
            #expect(ThemeRuntime.accent == nil)
            #expect(ThemeRuntime.accent2 == nil)
        }
        withRuntime(ThemePackage.find("anthropic-light")) {
            #expect(ThemeRuntime.accent?.hexString == "#D97757")
            #expect(ThemeRuntime.accent2?.hexString == "#5769F7")
        }
        let custom = ThemeRGB(hex: 0x123456)
        withRuntime(ThemePackage.find("anthropic-light"), accent: custom) {
            #expect(ThemeRuntime.accent == custom)
            #expect(ThemeRuntime.accent2?.hexString == "#5769F7")
        }
    }

    @Test("强调色预设解析:跟随主题为 nil,自定义用十六进制,非法自定义为 nil")
    func accentChoice() {
        #expect(AccentChoice.system.resolved(customHex: "#FFFFFF") == nil)
        #expect(AccentChoice.clay.resolved(customHex: "") == ThemeRGB(hex: 0xD97757))
        #expect(AccentChoice.custom.resolved(customHex: "#00FF00") == ThemeRGB(hex: 0x00FF00))
        #expect(AccentChoice.custom.resolved(customHex: "oops") == nil)
    }

    @Test("编辑器配色跟随主题包,系统主题恢复动态色")
    func editorFollowsTheme() throws {
        withRuntime(ThemePackage.find("cursor-dark")) {
            let theme = EditorTheme.default
            let expected = ThemePackage.find("cursor-dark").palette?.editorBackground.nsColor
            #expect(theme.background == expected)
        }
        withRuntime(.system) {
            let theme = EditorTheme.default
            #expect(theme.background != ThemePackage.find("cursor-dark").palette?.editorBackground.nsColor)
        }
    }

    @Test("Diff 配色:色盲主题的新增背景偏蓝")
    func diffPalette() throws {
        let palette = try #require(ThemePackage.find("cursor-light-colorblind").palette)
        #expect(palette.diffAdded.blue > palette.diffAdded.red)
    }

    @Test("设置页导航名为「主题」")
    func pageTitle() {
        #expect(SettingsPage.appearance.title == String(localized: "主题"))
    }
}
