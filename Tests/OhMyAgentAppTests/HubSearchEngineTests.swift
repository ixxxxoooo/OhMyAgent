// @author ixxxxoooo
// 中央搜索窗引擎测试:分类、空查询的「最近」视图、模糊排序、关键词命中与分段循环。

import Testing
@testable import OhMyAgentApp

@Suite("中央搜索引擎")
struct HubSearchEngineTests {
    private func candidate(_ id: String, _ segment: HubSegment, _ title: String, search: String? = nil, keywords: [String] = []) -> HubCandidate {
        HubCandidate(id: id, segment: segment, title: title, subtitle: nil, trailing: nil, icon: .symbol("file"),
                     searchText: search, keywords: keywords, action: .command(id: id))
    }

    private var fixtures: [HubCandidate] {
        [
            candidate("s1", .sessions, "修复路由大小写匹配"),
            candidate("s2", .sessions, "接入 Metrics 指标上报"),
            candidate("p1", .projects, "atlas-web"),
            candidate("f1", .files, "Router.swift", search: "Sources/Router.swift"),
            candidate("f2", .files, "Readme.md", search: "docs/Readme.md"),
            candidate("a1", .actions, "新建终端标签", keywords: ["操作", "命令"]),
            candidate("t1", .settings, "MCP", keywords: ["model context protocol", "服务器", "设置"]),
            candidate("th1", .themes, "Cursor 纸感", keywords: ["主题", "theme", "纸感", "浅色"]),
        ]
    }

    @Test("全部分类无查询:展示各分类代表项")
    func emptyAll() {
        let sections = HubSearchEngine.sections(query: "", segment: .all, candidates: fixtures)
        #expect(sections.map(\.id) == ["recent", "projects", "files", "actions", "settings", "themes"])
        #expect(sections.first?.items.map(\.id) == ["s1", "s2"])
        #expect(sections.first { $0.id == "files" }?.items.map(\.id) == ["f1", "f2"])
        #expect(sections.first { $0.id == "actions" }?.items.map(\.id) == ["a1"])
        #expect(sections.first { $0.id == "settings" }?.items.map(\.id) == ["t1"])
        #expect(sections.first { $0.id == "themes" }?.items.map(\.id) == ["th1"])
    }

    @Test("全部分类无查询:操作、设置、主题全量列出,不被代表项上限截断")
    func emptyAllListsEverything() {
        var many = fixtures
        for index in 0..<30 {
            many.append(candidate("act\(index)", .actions, "操作\(index)"))
            many.append(candidate("set\(index)", .settings, "设置页\(index)"))
            many.append(candidate("thm\(index)", .themes, "主题\(index)"))
        }
        let sections = HubSearchEngine.sections(query: "", segment: .all, candidates: many)
        #expect(sections.first { $0.id == "actions" }?.items.count == 31)
        #expect(sections.first { $0.id == "settings" }?.items.count == 31)
        #expect(sections.first { $0.id == "themes" }?.items.count == 31)
    }

    @Test("单分类无查询:列出该分类全部候选")
    func emptySegment() {
        let sections = HubSearchEngine.sections(query: "", segment: .files, candidates: fixtures)
        #expect(sections.count == 1)
        #expect(sections.first?.items.count == 2)
    }

    @Test("有查询时按固定顺序分组并过滤不匹配项")
    func queryGroups() {
        let sections = HubSearchEngine.sections(query: "rou", segment: .all, candidates: fixtures)
        #expect(sections.map(\.id) == ["files"])
        #expect(sections.first?.items.first?.id == "f1")
    }

    @Test("文件名命中高亮位置映射回标题")
    func highlightPositions() {
        let items = HubSearchEngine.rank("rou", fixtures.filter { $0.segment == .files }, limit: 5)
        #expect(items.first?.positions == [0, 1, 2])
    }

    @Test("标题未命中时用关键词匹配设置页")
    func keywordMatch() {
        let sections = HubSearchEngine.sections(query: "protocol", segment: .settings, candidates: fixtures)
        #expect(sections.first?.items.map(\.id) == ["t1"])
    }

    @Test("「全部」下每组数量受限")
    func allLimit() {
        let many = (0..<20).map { candidate("f\($0)", .files, "File\($0).swift", search: "a/File\($0).swift") }
        let sections = HubSearchEngine.sections(query: "file", segment: .all, candidates: many, allLimit: 3)
        #expect(sections.first?.items.count == 3)
    }

    @Test("分段按 Tab 循环切换")
    func segmentCycle() {
        #expect(HubSegment.all.next(by: 1) == .sessions)
        #expect(HubSegment.themes.next(by: 1) == .all)
        #expect(HubSegment.all.next(by: -1) == .themes)
    }

    @Test("画布候选可被单独或全局检索")
    func canvasSearch() {
        let canvas = candidate("c1", .canvases, "季度质量周报", keywords: ["画布", "canvas"])
        let global = HubSearchEngine.sections(query: "canvas", segment: .all, candidates: fixtures + [canvas])
        #expect(global.first { $0.id == "canvases" }?.items.first?.id == "c1")
        let single = HubSearchEngine.sections(query: "周报", segment: .canvases, candidates: fixtures + [canvas])
        #expect(single.first?.items.map(\.id) == ["c1"])
    }

    @Test("主题候选可被单独或全局检索")
    func themeSearch() {
        let theme = candidate("t-dracula", .themes, "Dracula", keywords: ["深色", "暗黑", "主题"])
        let sections = HubSearchEngine.sections(query: "dracula", segment: .all, candidates: fixtures + [theme])
        #expect(sections.map(\.id).contains("themes"))
        #expect(sections.first { $0.id == "themes" }?.items.first?.id == "t-dracula")
    }

    @Test("「全部」下可检索操作与设置")
    func allActionAndSettingsSearch() {
        let actionSections = HubSearchEngine.sections(query: "操作", segment: .all, candidates: fixtures)
        #expect(actionSections.first { $0.id == "actions" }?.items.first?.id == "a1")

        let settingSections = HubSearchEngine.sections(query: "设置", segment: .all, candidates: fixtures)
        #expect(settingSections.first { $0.id == "settings" }?.items.first?.id == "t1")
    }
}
