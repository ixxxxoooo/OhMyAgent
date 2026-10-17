// @author ixxxxoooo
// 代码高亮配色方案与自定义的解析逻辑测试。

import AppKit
import DesignSystem
import Testing
@testable import EditorKit

@MainActor
@Suite("SyntaxScheme", .serialized)
struct SyntaxSchemeTests {
    private func reset() {
        SyntaxPrefs.schemeID = SyntaxScheme.followThemeID
        SyntaxPrefs.overrides = [:]
    }

    @Test("内置方案 id 唯一,且浅色/深色变体各不相同")
    func builtInsAreWellFormed() {
        let ids = SyntaxScheme.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(SyntaxScheme.followThemeID))
        for scheme in SyntaxScheme.all {
            #expect(scheme.light != scheme.dark || scheme.id == "solarized", "\(scheme.name) 浅深变体相同")
        }
    }

    @Test("跟随主题且无自定义时不指定任何颜色")
    func followThemeIsInactive() {
        reset()
        #expect(!SyntaxPrefs.isActive)
        #expect(SyntaxPrefs.color(.keyword, dark: false) == nil)
    }

    @Test("选了方案按明暗取变体;自定义优先于方案,且浅深分开")
    func schemeAndOverrides() throws {
        reset()
        defer { reset() }
        SyntaxPrefs.schemeID = "github"
        let github = try #require(SyntaxScheme.find("github"))
        #expect(SyntaxPrefs.color(.string, dark: false) == github.light.string)
        #expect(SyntaxPrefs.color(.string, dark: true) == github.dark.string)
        SyntaxPrefs.overrides[SyntaxPrefs.overrideKey(.string, dark: true)] = "#112233"
        #expect(SyntaxPrefs.color(.string, dark: true)?.hexString == "#112233")
        #expect(SyntaxPrefs.color(.string, dark: false) == github.light.string)
    }

    @Test("缓存键随方案与自定义变化")
    func cacheKeyChanges() {
        reset()
        defer { reset() }
        let base = SyntaxPrefs.cacheKey
        SyntaxPrefs.schemeID = "nord"
        let withScheme = SyntaxPrefs.cacheKey
        SyntaxPrefs.overrides["light.keyword"] = "#FF0000"
        #expect(base != withScheme && withScheme != SyntaxPrefs.cacheKey)
    }

    @Test("编辑器主题叠加方案后关键字颜色变为方案色")
    func editorThemeAppliesScheme() throws {
        reset()
        defer { reset() }
        SyntaxPrefs.schemeID = "dracula"
        var theme = EditorTheme.default
        theme.applySyntaxPreferences(darkTheme: true)
        let expected = try #require(SyntaxScheme.find("dracula")).dark.keyword.nsColor
        let actual = try #require(theme.colors[.keyword]?.usingColorSpace(.sRGB))
        #expect(abs(actual.redComponent - expected.redComponent) < 0.01)
        #expect(abs(actual.greenComponent - expected.greenComponent) < 0.01)
    }
}
