// @author ixxxxoooo
// IDE 窗口注册表:根目录复用、强制新开、最近使用顺序、持久化往返、损坏文件回退、尺寸钳制。

import Foundation
import Testing
@testable import IDEKit

@MainActor
@Suite("IDE 窗口注册表")
struct IDEWindowRegistryTests {
    /// 每个测试一个独立临时文件。
    private func tempStore() -> IDEWindowStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oma-ide-windows-\(UUID().uuidString)", isDirectory: true)
        return IDEWindowStore(fileURL: dir.appendingPathComponent("ide-windows.json"))
    }

    @Test("同一根目录复用窗口,强制新开则另建")
    func reuseSameRoot() {
        let registry = IDEWindowRegistry(store: tempStore())
        let first = registry.open(root: "/tmp")
        #expect(first.created)
        let again = registry.open(root: "/tmp/")        // 末尾斜杠视为同一目录
        #expect(!again.created)
        #expect(again.model === first.model)
        let forced = registry.open(root: "/tmp", forceNew: true)
        #expect(forced.created)
        #expect(forced.model !== first.model)
        #expect(registry.windows.count == 2)
    }

    @Test("空窗口总是新建,且不参与根目录匹配")
    func emptyWindowsAreAlwaysNew() {
        let registry = IDEWindowRegistry(store: tempStore())
        let a = registry.open(root: nil)
        let b = registry.open(root: nil)
        #expect(a.created && b.created)
        #expect(registry.window(forRoot: nil) == nil)
        #expect(registry.window(forRoot: "") == nil)
    }

    @Test("激活把窗口移到最近使用的首位")
    func activateMovesToFront() {
        let registry = IDEWindowRegistry(store: tempStore())
        let a = registry.open(root: "/tmp/a").model
        let b = registry.open(root: "/tmp/b").model
        #expect(registry.mostRecent === b)
        registry.activate(a.id)
        #expect(registry.mostRecent === a)
        #expect(registry.windows.map(\.id) == [a.id, b.id])
        registry.activate(UUID())                         // 不存在的窗口:无副作用
        #expect(registry.windows.map(\.id) == [a.id, b.id])
    }

    @Test("移除窗口后不再出现在注册表")
    func removeWindow() {
        let registry = IDEWindowRegistry(store: tempStore())
        let a = registry.open(root: "/tmp/a").model
        registry.remove(a.id)
        #expect(registry.windows.isEmpty)
        #expect(registry.window(id: a.id) == nil)
    }

    @Test("持久化往返:尺寸、侧栏、顺序与外框都能恢复")
    func persistenceRoundTrip() {
        let store = tempStore()
        let registry = IDEWindowRegistry(store: store)
        let a = registry.open(root: "/tmp/a").model
        let b = registry.open(root: "/tmp/b").model
        a.setSidebarWidth(333)
        a.selectSidebar(.search)
        b.togglePanel()
        b.setPanelHeight(310)
        b.toggleAgentPane()
        b.frame = IDEWindowFrame(x: 10, y: 20, width: 900, height: 700)
        registry.activate(a.id)
        registry.saveNow()

        let restored = IDEWindowRegistry(store: store)
        #expect(restored.windows.map(\.id) == [a.id, b.id])
        let ra = restored.window(id: a.id)
        #expect(ra?.sidebarWidth == 333)
        #expect(ra?.sidebarView == .search)
        let rb = restored.window(id: b.id)
        #expect(rb?.panelVisible == true)
        #expect(rb?.panelHeight == 310)
        #expect(rb?.agentPaneVisible == false)
        #expect(rb?.frame == IDEWindowFrame(x: 10, y: 20, width: 900, height: 700))
    }

    @Test("损坏的状态文件:备份后以空状态启动")
    func corruptFileFallsBack() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ 不是 json".utf8).write(to: store.fileURL)
        let registry = IDEWindowRegistry(store: store)
        #expect(registry.windows.isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.corruptBackupURL.path))
    }

    @Test("越界尺寸与不可用外框在载入时被钳制")
    func clampOnLoad() throws {
        let store = tempStore()
        var snap = IDEWindowSnapshot(workspaceRoot: "/tmp")
        snap.sidebarWidth = 99_999
        snap.panelHeight = -5
        snap.agentPaneWidth = 50
        snap.frame = IDEWindowFrame(x: 0, y: 0, width: 10, height: 10)
        try store.save(IDEWindowsState(windows: [snap, snap]))     // 重复标识只保留一份
        let registry = IDEWindowRegistry(store: store)
        #expect(registry.windows.count == 1)
        let model = try #require(registry.windows.first)
        #expect(model.sidebarWidth == IDEMetrics.sidebarRange.upperBound)
        #expect(model.panelHeight == IDEMetrics.panelRange.lowerBound)
        #expect(model.agentPaneWidth == IDEMetrics.agentRange.lowerBound)
        #expect(model.frame == nil)
    }
}

@MainActor
@Suite("IDE 窗口模型")
struct IDEWindowModelTests {
    @Test("再次点击当前活动栏图标收起侧栏,点另一个则切换并展开")
    func selectSidebarToggles() {
        let model = IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: "/tmp"))
        #expect(model.sidebarVisible && model.sidebarView == .explorer)
        model.selectSidebar(.explorer)
        #expect(!model.sidebarVisible)
        model.selectSidebar(.scm)
        #expect(model.sidebarVisible && model.sidebarView == .scm)
    }

    @Test("收起底部面板同时取消最大化")
    func collapsingPanelClearsMaximize() {
        let model = IDEWindowModel(snapshot: IDEWindowSnapshot())
        model.togglePanel()
        model.panelMaximized = true
        model.togglePanel()
        #expect(!model.panelVisible && !model.panelMaximized)
    }

    @Test("尺寸设置被钳制到范围内")
    func sizesAreClamped() {
        let model = IDEWindowModel(snapshot: IDEWindowSnapshot())
        model.setSidebarWidth(1)
        #expect(model.sidebarWidth == IDEMetrics.sidebarRange.lowerBound)
        model.setAgentPaneWidth(1_000_000)
        #expect(model.agentPaneWidth == IDEMetrics.agentRange.upperBound)
        model.setPanelHeight(.infinity)
        #expect(model.panelHeight == IDEMetrics.panelDefault)
    }

    @Test("变更触发回调,值未变化不触发")
    func changeCallback() {
        let model = IDEWindowModel(snapshot: IDEWindowSnapshot())
        var count = 0
        model.onChange = { count += 1 }
        model.sidebarWidth = model.sidebarWidth
        #expect(count == 0)
        model.toggleSidebar()
        #expect(count == 1)
    }
}

@Suite("IDE 度量")
struct IDEMetricsTests {
    @Test("为编辑区保留最小宽度")
    func reservesEditorWidth() {
        // 窗口 1000:活动栏 48 + Agent 380 + 编辑区 320 → 侧栏最多 252,但不小于下限 180
        #expect(IDEMetrics.sidebarMax(window: 1000, agentWidth: 380) == 252)
        #expect(IDEMetrics.sidebarMax(window: 500, agentWidth: 380) == IDEMetrics.sidebarRange.lowerBound)
        #expect(IDEMetrics.agentMax(window: 1000, sidebarWidth: 260) == 372)
    }

    @Test("根目录规范化:去末尾斜杠、空串为 nil")
    func normalizedRoot() {
        #expect(IDEMetrics.normalizedRoot(nil) == nil)
        #expect(IDEMetrics.normalizedRoot("") == nil)
        #expect(IDEMetrics.normalizedRoot("/tmp/") == IDEMetrics.normalizedRoot("/tmp"))
        #expect(IDEMetrics.normalizedRoot("/tmp/a/../b") == IDEMetrics.normalizedRoot("/tmp/b"))
    }
}

@MainActor
@Suite("IDE 编辑器标签")
struct IDEEditorTabsTests {
    private func make() -> IDEWindowModel { IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: "/tmp")) }

    @Test("单击预览会被下一个预览替换,固定后保留")
    func previewReplacement() {
        let model = make()
        model.openFile("/tmp/a.swift")
        model.openFile("/tmp/b.swift")
        #expect(model.openFilePaths == ["/tmp/b.swift"])
        model.openFile("/tmp/b.swift", preview: false)          // 双击固定
        model.openFile("/tmp/c.swift")
        #expect(model.openFilePaths == ["/tmp/b.swift", "/tmp/c.swift"])
        #expect(model.activeFilePath == "/tmp/c.swift")
    }

    @Test("重复打开只聚焦不新增,并更新行号")
    func reopenFocusesAndSetsLine() {
        let model = make()
        model.openFile("/tmp/a.swift", preview: false)
        model.openFile("/tmp/b.swift", preview: false)
        let id = model.openFile("/tmp/a.swift", line: 42, preview: false)
        #expect(model.openFilePaths.count == 2)
        #expect(model.activeFilePath == "/tmp/a.swift")
        #expect(model.editor.tab(id ?? UUID())?.line == 42)
    }

    @Test("在侧边打开会新建分屏")
    func openBesideSplits() {
        let model = make()
        model.openFile("/tmp/a.swift", preview: false)
        model.openFile("/tmp/b.swift", preview: false, beside: true)
        #expect(model.editor.groups.count == 2)
        #expect(model.activeFilePath == "/tmp/b.swift")
    }

    @Test("文件或目录被删除时关闭其下的标签")
    func closeUnderPath() {
        let model = make()
        for name in ["d/a.swift", "d/b.swift", "e.swift"] { model.openFile("/tmp/" + name, preview: false) }
        model.closeFileTabs(under: "/tmp/d")
        #expect(model.openFilePaths == ["/tmp/e.swift"])
    }

    @Test("重命名目录后其下标签改指新路径")
    func retargetOnRename() {
        let model = make()
        model.openFile("/tmp/d/a.swift", preview: false)
        model.retargetFileTabs(from: "/tmp/d", to: "/tmp/x")
        #expect(model.openFilePaths == ["/tmp/x/a.swift"])
    }

    @Test("脏标记同步到指向该文件的标签")
    func dirtyFlag() {
        let model = make()
        let id = model.openFile("/tmp/a.swift", preview: false)
        model.setDirty(true, forFile: "/tmp/a.swift")
        #expect(model.editor.tab(id ?? UUID())?.isDirty == true)
        model.setDirty(false, forFile: "/tmp/a.swift")
        #expect(model.editor.tab(id ?? UUID())?.isDirty == false)
    }

    @Test("空路径被忽略")
    func emptyPath() {
        let model = make()
        #expect(model.openFile("") == nil)
        #expect(model.editor.allTabs.isEmpty)
    }
}
