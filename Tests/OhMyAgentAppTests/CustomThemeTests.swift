// @author ixxxxoooo
// 自定义主题:JSON 往返、校验、磁盘存取与风格夹取。

import DesignSystem
import Foundation
import Testing

@Suite("自定义主题", .serialized)
struct CustomThemeTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("内置主题导出后再导入,颜色与风格保持一致")
    func roundTrip() throws {
        let source = ThemePackage.find("dracula")
        let file = try #require(CustomThemeFile.export(source, id: "my-dracula", name: "我的 Dracula"))
        let data = try file.encoded()
        let imported = try CustomThemeFile.decode(data).makePackage()
        #expect(imported.id == "custom-my-dracula" && imported.group == .custom && imported.tone == .dark)
        let a = try #require(source.palette), b = try #require(imported.palette)
        #expect(a.accent == b.accent && a.surface == b.surface && a.keyword == b.keyword)
        #expect(a.style == b.style)
        #expect(a.ansiColors.map(\.hexString) == b.ansiColors.map(\.hexString))
    }

    @Test("校验:空名称、非法基线、非法颜色、错误 ANSI、未知版本都被拒绝")
    func validation() {
        #expect(throws: CustomThemeError.emptyName) { try CustomThemeFile(id: "a", name: "  ", base: "dark").makePackage() }
        #expect(throws: CustomThemeError.invalidBase) { try CustomThemeFile(id: "a", name: "A", base: "blue").makePackage() }
        #expect(throws: CustomThemeError.invalidColor(key: "accent")) { try CustomThemeFile(id: "a", name: "A", base: "dark", colors: ["accent": "red"]).makePackage() }
        #expect(throws: CustomThemeError.invalidANSI) { try CustomThemeFile(id: "a", name: "A", base: "dark", ansi: ["#000000"]).makePackage() }
        var future = CustomThemeFile(id: "a", name: "A", base: "dark")
        future.version = 9
        #expect(throws: CustomThemeError.unsupportedVersion(9)) { try future.makePackage() }
        #expect(throws: CustomThemeError.invalidJSON) { try CustomThemeFile.decode(Data("nope".utf8)) }
    }

    @Test("缺省颜色沿用基线;未知键忽略;侧栏与内容区不同;风格被夹在安全范围")
    func defaultsAndClamp() throws {
        let file = CustomThemeFile(id: "Hello World!", name: "测试", base: "light", colors: ["accent": "#112233", "bogus": "#ffffff"], style: ["cornerScale": 9, "shadowScale": -3])
        let package = try file.makePackage()
        #expect(package.id == "custom-hello-world")
        let palette = try #require(package.palette)
        #expect(palette.accent.hexString == "#112233")
        #expect(palette.surface == ThemePalette.lightBase.surface)
        #expect(palette.sidebarBackground != palette.surface)
        #expect(palette.style.cornerScale == 1.6 && palette.style.shadowScale == 0)
    }

    @Test("磁盘存取:保存、读取、删除;无效文件被跳过")
    func store() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = try CustomThemeStore.save(CustomThemeFile(id: "ocean", name: "海洋", base: "dark", colors: ["accent": "#00AAFF"]), to: dir)
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("bad.json"))
        let loaded = CustomThemeStore.loadAll(from: dir)
        #expect(loaded.map(\.id) == [saved.id])
        CustomThemeStore.delete(id: saved.id, from: dir)
        #expect(CustomThemeStore.loadAll(from: dir).isEmpty)
    }

    @Test("系统主题没有调色板,无法导出")
    func exportSystem() {
        #expect(CustomThemeFile.export(.system) == nil)
    }
}
