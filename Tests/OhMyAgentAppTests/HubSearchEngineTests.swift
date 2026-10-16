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
            candidate("a1", .actions, "新建终端标签"),
            candidate("t1", .settings, "MCP", keywords: ["model context protocol", "服务器"]),
        ]
    }

    @Test("全部分类无查询:只显示最近会话与项目")
    func emptyAll() {
        let sections = HubSearchEngine.sections(query: "", segment: .all, candidates: fixtures)
        #expect(sections.map(\.id) == ["recent", "projects"])
        #expect(sections.first?.items.map(\.id) == ["s1", "s2"])
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
        #expect(HubSegment.settings.next(by: 1) == .all)
        #expect(HubSegment.all.next(by: -1) == .settings)
    }
}
