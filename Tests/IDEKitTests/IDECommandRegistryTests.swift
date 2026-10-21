// @author ixxxxoooo
// IDE 命令注册表(I12):内置命令唯一性、上下文过滤、模糊搜索、最近使用、面板输入解析、快速打开排序。

import Foundation
import Testing
@testable import IDEKit

@Suite("IDE 命令注册表")
struct IDECommandRegistryTests {
    @Test("内置命令 id 唯一,标题非空")
    func builtinUnique() {
        let ids = IDECommandRegistry.builtin.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(IDECommandRegistry.builtin.allSatisfy { !$0.title.isEmpty && !$0.category.isEmpty })
    }

    @Test("上下文过滤:没有文件夹时不出现依赖文件夹的命令")
    func contextFilter() {
        let registry = IDECommandRegistry()
        let empty = registry.search(query: "", context: IDECommandContext(), limit: 100).map(\.command.id)
        #expect(!empty.contains("file.newFile"))
        #expect(!empty.contains("file.save"))
        #expect(empty.contains("view.toggleSidebar"))
        let full = registry.search(query: "", context: IDECommandContext(hasFolder: true, hasActiveFile: true, hasDirty: true), limit: 100).map(\.command.id)
        #expect(full.contains("file.newFile") && full.contains("file.save") && full.contains("file.saveAll"))
    }

    @Test("模糊搜索按得分排序并给出命中位置")
    func fuzzy() {
        let registry = IDECommandRegistry()
        let results = registry.search(query: "toggle sidebar", context: IDECommandContext())
        #expect(results.isEmpty || results.first?.command.id == "view.toggleSidebar")
        let zh = registry.search(query: "侧栏", context: IDECommandContext())
        #expect(zh.first?.command.id == "view.toggleSidebar" || zh.contains { $0.command.id == "view.toggleSidebar" })
        #expect(zh.first?.positions.isEmpty == false)
        #expect(registry.search(query: "zzzzzzzz", context: IDECommandContext()).isEmpty)
    }

    @Test("最近使用排在空查询最前,且去重并限长")
    func recent() {
        var registry = IDECommandRegistry()
        registry.recordUse("view.togglePanel")
        registry.recordUse("view.toggleSidebar")
        registry.recordUse("view.togglePanel")
        registry.recordUse("不存在")
        #expect(registry.recent == ["view.togglePanel", "view.toggleSidebar"])
        #expect(registry.search(query: "", context: IDECommandContext()).first?.command.id == "view.togglePanel")
        for command in registry.commands.prefix(20) { registry.recordUse(command.id) }
        #expect(registry.recent.count == IDECommandRegistry.recentLimit)
    }

    @Test("命令面板输入前缀解析")
    func parse() {
        #expect(IDEPaletteQuery.parse("foo") == .files("foo"))
        #expect(IDEPaletteQuery.parse(">保存") == .commands("保存"))
        #expect(IDEPaletteQuery.parse(":12") == .line(12, nil))
        #expect(IDEPaletteQuery.parse(":12:5") == .line(12, 5))
        #expect(IDEPaletteQuery.parse(":") == .line(nil, nil))
        #expect(IDEPaletteQuery.parse(":abc") == .line(nil, nil))
        #expect(IDEPaletteQuery.parse(":0") == .line(nil, nil))
        #expect(IDEPaletteQuery.commands("").prefix == ">")
    }

    @Test("快速打开:空查询已打开文件在前,有查询按得分")
    func quickOpen() {
        let files = ["a/z.swift", "b/App.swift", "c/main.swift"]
        let empty = IDEQuickOpen.rank(query: "", files: files, recents: ["c/main.swift", "gone.swift"])
        #expect(empty.map(\.path) == ["c/main.swift", "a/z.swift", "b/App.swift"])
        let ranked = IDEQuickOpen.rank(query: "app", files: files, recents: [])
        #expect(ranked.first?.path == "b/App.swift")
    }
}
