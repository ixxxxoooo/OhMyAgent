// @author ixxxxoooo
// 工作台模型测试:项目增删、选择、持久化、布局折叠与历史缓存。

import ACPKit
import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("工作台模型")
struct WorkbenchTests {
    /// 每个测试独立的状态文件与项目目录。
    private func makeEnvironment() throws -> (store: WorkbenchStore, root: URL, dirs: [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-wb-\(UUID().uuidString)")
        let dirs = try ["alpha", "beta", "gamma"].map { name -> URL in
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return (WorkbenchStore(fileURL: root.appendingPathComponent("state/workbench.json")), root, dirs)
    }

    private func makeModel(_ store: WorkbenchStore) -> WorkbenchModel {
        WorkbenchModel(store: store, autoConnect: false) { url in
            let session = SessionModel(workspace: url)
            session.attention = AttentionCenter()
            return session
        }
    }

    @Test("添加项目去重并选中,不存在的目录被拒绝")
    func addProjects() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = makeModel(env.store)
        let first = model.openProject(env.dirs[0])
        #expect(first == env.dirs[0].standardizedFileURL.path)
        #expect(model.openProject(env.dirs[0]) == first)
        #expect(model.projects.count == 1)
        #expect(model.openProject(env.root.appendingPathComponent("nope")) == nil)
        #expect(model.openProject(env.root.appendingPathComponent("alpha/../beta")) != nil)
        #expect(model.projects.count == 2)
        #expect(model.selectedProject?.name == "beta")
        model.shutdownAll()
    }

    @Test("选中项目时按需创建会话,移除项目回收会话并改选")
    func selectAndRemove() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = makeModel(env.store)
        let a = try #require(model.openProject(env.dirs[0]))
        let b = try #require(model.openProject(env.dirs[1]))
        #expect(model.sessions.count == 2)
        #expect(model.activeSession?.workspace.standardizedFileURL.path == b)
        model.select(project: a)
        #expect(model.activeSession?.workspace.standardizedFileURL.path == a)
        model.removeProject(a)
        #expect(model.sessions[a] == nil)
        #expect(model.selectedProjectID == b)
        model.shutdownAll()
    }

    @Test("置顶项目排在最前,其余按最近打开排序")
    func ordering() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = makeModel(env.store)
        let a = try #require(model.openProject(env.dirs[0], now: Date(timeIntervalSince1970: 100)))
        _ = model.openProject(env.dirs[1], now: Date(timeIntervalSince1970: 200))
        let c = try #require(model.openProject(env.dirs[2], now: Date(timeIntervalSince1970: 300)))
        #expect(model.orderedProjects.map(\.name) == ["gamma", "beta", "alpha"])
        model.togglePin(a)
        #expect(model.orderedProjects.first?.id == a)
        model.togglePin(c)
        #expect(model.orderedProjects.map(\.name) == ["gamma", "alpha", "beta"])
        model.shutdownAll()
    }

    @Test("布局与项目列表持久化并在重建后恢复")
    func persistence() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = makeModel(env.store)
        let a = try #require(model.openProject(env.dirs[0]))
        _ = model.openProject(env.dirs[1])
        model.togglePin(a)
        model.layout.leftVisible = false
        model.layout.rightVisible = true
        model.layout.leftWidth = 300
        model.layout.bottomHeight = 333
        model.saveNow()
        model.shutdownAll()

        let restored = makeModel(env.store)
        #expect(restored.projects.count == 2)
        #expect(restored.projects.first { $0.id == a }?.pinned == true)
        #expect(restored.layout.leftVisible == false)
        #expect(restored.layout.rightVisible == true)
        #expect(restored.layout.leftWidth == 300)
        #expect(restored.layout.bottomHeight == 333)
        #expect(restored.selectedProject?.name == "beta")
        restored.shutdownAll()
    }

    @Test("损坏或越界的状态文件回退到安全布局;已删除的目录被过滤")
    func corruptState() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try FileManager.default.createDirectory(at: env.store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ 不是 json".write(to: env.store.fileURL, atomically: true, encoding: .utf8)
        let broken = makeModel(env.store)
        #expect(broken.projects.isEmpty)
        #expect(broken.layout == WorkbenchLayout())

        var state = WorkbenchState()
        state.layout.leftWidth = 5
        state.layout.rightWidth = 9999
        state.layout.bottomHeight = -1
        state.projects = [ProjectEntry(url: env.dirs[0]), ProjectEntry(url: env.root.appendingPathComponent("已删除"))]
        try env.store.save(state)
        let model = makeModel(env.store)
        #expect(model.layout.leftWidth == 180 && model.layout.rightWidth == 800 && model.layout.bottomHeight == 120)
        #expect(model.projects.count == 1)
        model.shutdownAll()
    }

    @Test("折叠、面板切换与历史缓存")
    func panesAndCache() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = makeModel(env.store)
        let a = try #require(model.openProject(env.dirs[0]))
        model.toggleLeft(); model.toggleRight(); model.toggleBottom()
        #expect(!model.layout.leftVisible && model.layout.rightVisible && model.layout.bottomVisible)
        model.layout.rightVisible = false
        model.showRight(.git)
        #expect(model.layout.rightVisible && model.layout.rightPane == .git)
        // 已下线的旧视图被校正回「文件」
        model.layout.rightPane = .plan
        model.layout.clamp()
        #expect(model.layout.rightPane == .files)
        model.showBottom(.output)
        #expect(model.layout.bottomVisible)
        model.toggleCollapsed(a)
        #expect(model.projects[0].collapsed)
        let history = (0..<40).map { SessionSummary(sessionId: "s\($0)", cwd: a, title: "会话\($0)", updatedAt: nil) }
        model.cacheHistory(history, for: a)
        #expect(model.projects[0].sessions.count == 30)
        #expect(model.projects[0].sessions.first?.title == "会话0")
        model.shutdownAll()
    }

    @Test("项目排序:置顶优先,其后按添加时间倒序,稳定不随选中变化")
    func projectOrdering() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = makeModel(env.store)
        // 添加之间留出间隔,保证 addedAt 严格递增
        let a = try #require(model.openProject(env.dirs[0]))
        try await Task.sleep(for: .milliseconds(20))
        let b = try #require(model.openProject(env.dirs[1]))
        try await Task.sleep(for: .milliseconds(20))
        let c = try #require(model.openProject(env.dirs[2]))
        #expect(model.orderedProjects.map(\.id) == [c, b, a])
        model.select(project: a)
        #expect(model.orderedProjects.map(\.id) == [c, b, a])
        model.togglePin(a)
        #expect(model.orderedProjects.map(\.id) == [a, c, b])
        model.shutdownAll()
    }

    @Test("一键折叠/展开全部项目")
    func collapseAllProjects() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = makeModel(env.store)
        #expect(model.allProjectsCollapsed == false)
        _ = model.openProject(env.dirs[0])
        _ = model.openProject(env.dirs[1])
        #expect(model.allProjectsCollapsed == false)
        model.setAllProjectsCollapsed(true)
        #expect(model.projects.allSatisfy { $0.collapsed })
        #expect(model.allProjectsCollapsed)
        model.setAllProjectsCollapsed(false)
        #expect(model.projects.allSatisfy { !$0.collapsed })
        model.shutdownAll()
    }

    @Test("历史会话排序键:首次填充冻结为更新时间,之后新出现的会话以出现时刻为准")
    func firstSeenAtStability() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = makeModel(env.store)
        let a = try #require(model.openProject(env.dirs[0]))
        let first = [
            SessionSummary(sessionId: "old", cwd: a, title: "旧", updatedAt: "2026-01-01T00:00:00Z"),
        ]
        model.cacheHistory(first, for: a, now: Date(timeIntervalSince1970: 1_800_000_000))
        let cached = try #require(model.projects.first?.sessions.first)
        #expect(cached.firstSeenAt == "2026-01-01T00:00:00Z")
        // 旧会话被更新(updatedAt 变化)后,排序键不变;新会话获得当前时刻
        let second = [
            SessionSummary(sessionId: "old", cwd: a, title: "旧", updatedAt: "2026-06-01T00:00:00Z"),
            SessionSummary(sessionId: "new", cwd: a, title: "新", updatedAt: "2026-06-01T00:00:00Z"),
        ]
        model.cacheHistory(second, for: a, now: Date(timeIntervalSince1970: 1_800_000_000))
        let sessions = try #require(model.projects.first?.sessions)
        let old = try #require(sessions.first { $0.sessionId == "old" })
        let new = try #require(sessions.first { $0.sessionId == "new" })
        #expect(old.firstSeenAt == "2026-01-01T00:00:00Z")
        #expect(new.stableKey > old.stableKey)
        model.shutdownAll()
    }

    @Test("回退/前进:在已激活过的标签之间移动")
    func backAndForward() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = makeModel(env.store)
        let a = try #require(model.openProject(env.dirs[0]))
        let file1 = env.dirs[0].appendingPathComponent("a.txt").path
        let file2 = env.dirs[0].appendingPathComponent("b.txt").path
        let t0 = model.dock.focusedGroup?.activeID
        model.recordNavigation()
        let t1 = model.openFile(file1, preview: false)
        model.recordNavigation()
        let t2 = model.openFile(file2, preview: false)
        model.recordNavigation()
        #expect(model.nav.canGoBack)
        model.goBack()
        #expect(model.dock.focusedGroup?.activeID == t1)
        model.goBack()
        #expect(model.dock.focusedGroup?.activeID == t0)
        #expect(model.nav.canGoBack == false)
        model.goForward()
        #expect(model.dock.focusedGroup?.activeID == t1)
        model.goForward()
        #expect(model.dock.focusedGroup?.activeID == t2)
        #expect(model.nav.canGoForward == false)
        _ = a
        model.shutdownAll()
    }
}

@Suite("侧栏尺寸")
struct PanelMetricsTests {
    @Test("宽度限制在允许范围内")
    func clamping() {
        #expect(PanelMetrics.clamp(100, side: .left) == 180)
        #expect(PanelMetrics.clamp(900, side: .left) == 520)
        #expect(PanelMetrics.clamp(100, side: .right) == 240)
        #expect(PanelMetrics.clamp(2000, side: .right) == 800)
        #expect(PanelMetrics.clamp(300, side: .left) == 300)
    }

    @Test("拖动换算:左栏向右变宽,右栏向左变宽,并受范围约束")
    func resizing() {
        #expect(PanelMetrics.resized(base: 260, translation: 40, side: .left) == 300)
        #expect(PanelMetrics.resized(base: 260, translation: -200, side: .left) == 180)
        #expect(PanelMetrics.resized(base: 340, translation: -60, side: .right) == 400)
        #expect(PanelMetrics.resized(base: 340, translation: 500, side: .right) == 240)
    }

    @Test("默认宽度在各自范围内")
    func defaults() {
        #expect(PanelMetrics.range(for: .left).contains(PanelMetrics.defaultWidth(for: .left)))
        #expect(PanelMetrics.range(for: .right).contains(PanelMetrics.defaultWidth(for: .right)))
    }
}

@Suite("标签导航历史")
struct NavHistoryTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test("相邻去重;前进/后退按浏览器语义移动")
    func pushBackForward() {
        var nav = NavHistory()
        nav.push(a); nav.push(a); nav.push(b); nav.push(c)
        #expect(nav.entries == [a, b, c])
        #expect(nav.canGoBack && !nav.canGoForward)
        #expect(nav.back() == b)
        #expect(nav.back() == a)
        #expect(nav.back() == nil)
        #expect(nav.forward() == b)
        #expect(nav.canGoForward)
    }

    @Test("从中间导航会截断前进记录")
    func truncateForward() {
        var nav = NavHistory()
        nav.push(a); nav.push(b); nav.push(c)
        _ = nav.back()
        nav.push(d)
        #expect(nav.entries == [a, b, d])
        #expect(!nav.canGoForward)
    }

    @Test("超过上限裁剪最旧记录")
    func limit() {
        var nav = NavHistory()
        for _ in 0..<(NavHistory.limit + 10) { nav.push(UUID()) }
        #expect(nav.entries.count == NavHistory.limit)
        #expect(nav.cursor == NavHistory.limit - 1)
    }

    @Test("清理已关闭标签并修正游标")
    func prune() {
        var nav = NavHistory()
        nav.push(a); nav.push(b); nav.push(c)
        nav.prune(alive: [a, c])
        #expect(nav.entries == [a, c])
        #expect(nav.cursor == 1)
        // 当前记录被移除:回退到最近保留的前驱
        nav.prune(alive: [a])
        #expect(nav.entries == [a])
        #expect(nav.cursor == 0)
        nav.prune(alive: [])
        #expect(nav.entries.isEmpty)
        #expect(nav.cursor == -1)
    }
}
