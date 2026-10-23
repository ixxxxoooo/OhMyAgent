// @author ixxxxoooo
// 项目栏行快照:分区、折叠、预览截断、显示更多、置顶与归档筛选、排序。

import ChatKit
import Foundation
import Testing
@testable import OhMyAgentApp
@testable import WorkbenchKit

@MainActor
@Suite("项目栏行快照")
struct SidebarRowsTests {
    private func makeModel() -> WorkbenchModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oma-sb-\(UUID().uuidString)/w.json")
        return WorkbenchModel(store: WorkbenchStore(fileURL: url), autoConnect: false) { SessionModel(workspace: $0) }
    }

    /// 创建时间递增的缓存会话(`s0` 最旧)。
    private func sessions(_ prefix: String, count: Int) -> [CachedSession] {
        (0..<count).map { index in
            CachedSession(sessionId: "\(prefix)\(index)", title: "标题\(prefix)\(index)",
                          updatedAt: nil, createdAt: String(format: "2026-01-%02dT00:00:00Z", index + 1))
        }
    }

    private func project(_ name: String, sessions: [CachedSession] = [], collapsed: Bool = false) -> ProjectEntry {
        var entry = ProjectEntry(url: URL(fileURLWithPath: "/tmp/oma-sb-tests/\(name)"))
        entry.sessions = sessions
        entry.collapsed = collapsed
        return entry
    }

    private func sessionIDs(_ rows: [SidebarRow], key: String) -> [String] {
        rows.compactMap { row -> String? in
            guard case .session(let item, _, _, _) = row.kind, row.id.hasPrefix("\(key):") else { return nil }
            return item.sessionId
        }
    }

    @Test("预览只取最新 5 条,按创建时间倒序,其余走「显示更多」;点开后全部展示")
    func previewAndMore() {
        let model = makeModel()
        let entry = project("a", sessions: sessions("a", count: 8))
        model.projects = [entry]
        let collapsedRows = model.sidebarRows(showArchived: false, expandedMore: [])
        #expect(sessionIDs(collapsedRows, key: entry.id) == ["a7", "a6", "a5", "a4", "a3"])
        let more = collapsedRows.first { $0.id == "more:\(entry.id)" }
        if case .more(_, let expanded, let remaining, _)? = more?.kind {
            #expect(!expanded)
            #expect(remaining == 3)
        } else {
            Issue.record("缺少「显示更多」行")
        }
        let expandedRows = model.sidebarRows(showArchived: false, expandedMore: [entry.id])
        #expect(sessionIDs(expandedRows, key: entry.id).count == 8)
    }

    @Test("折叠的项目只有标题行(带会话数),空项目有提示行")
    func collapsedAndEmpty() {
        let model = makeModel()
        let folded = project("b", sessions: sessions("b", count: 3), collapsed: true)
        let empty = project("c")
        model.projects = [folded, empty]
        let rows = model.sidebarRows(showArchived: false, expandedMore: [])
        if case .project(_, let count)? = rows.first(where: { $0.id == "project:\(folded.id)" })?.kind {
            #expect(count == 3)
        } else {
            Issue.record("缺少折叠项目标题行")
        }
        #expect(sessionIDs(rows, key: folded.id).isEmpty)
        #expect(rows.contains { $0.id == "hint:\(empty.id)" })
    }

    @Test("置顶会话进入「置顶」分区且不再出现在项目里;归档默认隐藏、开关打开后可见")
    func pinnedAndArchived() {
        let model = makeModel()
        var entry = project("d", sessions: sessions("d", count: 4))
        entry.pinnedSessions = ["d3"]
        entry.archivedSessions = ["d2"]
        model.projects = [entry]
        let hidden = model.sidebarRows(showArchived: false, expandedMore: [])
        #expect(hidden.contains { $0.id == "title:pinned" })
        #expect(sessionIDs(hidden, key: entry.id) == ["d1", "d0"])
        if case .project(_, let count)? = hidden.first(where: { $0.id == "project:\(entry.id)" })?.kind { #expect(count == 2) }
        let shown = model.sidebarRows(showArchived: true, expandedMore: [])
        #expect(sessionIDs(shown, key: entry.id) == ["d2", "d1", "d0"])
    }

    @Test("没有置顶时不出现「置顶」分区;行 ID 唯一;占位高度含 2pt 行间距")
    func structure() {
        let model = makeModel()
        model.projects = [project("e", sessions: sessions("e", count: 12)), project("f", sessions: sessions("f", count: 2))]
        let rows = model.sidebarRows(showArchived: false, expandedMore: [])
        #expect(!rows.contains { $0.id == "title:pinned" })
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.allSatisfy { $0.cellHeight == $0.height + 2 })
    }

    @Test("「归档下方全部」的兄弟序列:同列表全部会话 ID,按行位置取后缀")
    func siblings() {
        let model = makeModel()
        let entry = project("g", sessions: sessions("g", count: 8))
        model.projects = [entry]
        let rows = model.sidebarRows(showArchived: false, expandedMore: [])
        guard case .session(_, _, let ids, let index)? = rows.first(where: { $0.id.hasPrefix("\(entry.id):") })?.kind else {
            Issue.record("缺少会话行")
            return
        }
        #expect(ids.count == 8)
        #expect(index == 0)
    }

    @Test("按模式过滤:会话模式只含通用会话,代码模式只含工作区")
    func scopeFiltersSections() {
        let model = makeModel()
        var chat = project("chat", sessions: sessions("c", count: 2))
        chat.isChatArea = true
        let work = project("w", sessions: sessions("w", count: 2))
        model.projects = [chat, work]
        let titles: (SidebarScope) -> [String] = { scope in
            model.sidebarRows(showArchived: false, expandedMore: [], scope: scope).compactMap { row in
                if case .title(let kind) = row.kind { return "\(kind)" } else { return nil }
            }
        }
        #expect(titles(.chat) == ["general"])
        #expect(titles(.code) == ["workspace"])
        #expect(titles(.all) == ["general", "workspace"])
        let codeRows = model.sidebarRows(showArchived: false, expandedMore: [], scope: .code)
        #expect(sessionIDs(codeRows, key: work.id) == ["w1", "w0"])
        #expect(sessionIDs(codeRows, key: "general").isEmpty)
        #expect(SidebarScope(pane: .sessions) == .chat && SidebarScope(pane: .workspaces) == .code)
    }
}
