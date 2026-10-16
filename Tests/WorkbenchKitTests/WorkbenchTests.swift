// @author ygw
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
}

@Suite("侧栏分隔条")
struct PanelDividerTests {
    private let three = [
        PanelColumn(minX: 0, maxX: 260, hidden: false),
        PanelColumn(minX: 261, maxX: 900, hidden: false),
        PanelColumn(minX: 901, maxX: 1240, hidden: false),
    ]

    @Test("三列:左分隔条属于左栏,右分隔条属于右栏,中间不命中")
    func threeColumns() {
        #expect(PanelDividers.side(at: 260.5, columns: three, leftVisible: true, rightVisible: true) == .left)
        #expect(PanelDividers.side(at: 900.5, columns: three, leftVisible: true, rightVisible: true) == .right)
        #expect(PanelDividers.side(at: 500, columns: three, leftVisible: true, rightVisible: true) == nil)
    }

    @Test("左栏折叠:唯一的分隔条属于右栏")
    func leftCollapsed() {
        var columns = three
        columns[0].hidden = true
        #expect(PanelDividers.side(at: 900.5, columns: columns, leftVisible: false, rightVisible: true) == .right)
    }

    @Test("两列:按显隐状态判别")
    func twoColumns() {
        let columns = [PanelColumn(minX: 0, maxX: 260, hidden: false), PanelColumn(minX: 261, maxX: 900, hidden: false)]
        #expect(PanelDividers.side(at: 260.5, columns: columns, leftVisible: true, rightVisible: false) == .left)
        #expect(PanelDividers.side(at: 260.5, columns: columns, leftVisible: false, rightVisible: true) == .right)
    }
}
