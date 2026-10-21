// @author ixxxxoooo
// IDE 窗口工作区上下文测试:名称校验、文件树配置、定位展开祖先、拖放规划落到标签改指。

import Foundation
import IDEKit
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("IDE 工作区上下文")
struct IDEWorkspaceTests {
    private func makeRoot() throws -> String {
        // 不用系统临时目录:/var 是 /private/var 的符号链接,窗口模型与文件树对它的写法不一致;缓存目录没有符号链接
        let base = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
        let root = base + "/oma-ide-workspace-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: root + "/a/b/c.txt"))
        return root
    }

    @Test("名称校验拒绝空串、斜杠、点与点点")
    func nameValidation() {
        #expect(IDEWorkspace.isValidName("main.swift"))
        for bad in ["", "a/b", ".", ".."] { #expect(!IDEWorkspace.isValidName(bad)) }
        #expect(IDEWorkspace.nameError("ok") == nil)
        #expect(IDEWorkspace.nameError("a/b") != nil)
    }

    @Test("定位文件会展开所有祖先目录")
    func revealExpandsAncestors() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = IDEWorkspace(model: IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: root)))
        workspace.configureTree()
        workspace.reveal(root + "/a/b/c.txt")
        #expect(workspace.tree.expanded.contains(root + "/a"))
        #expect(workspace.tree.expanded.contains(root + "/a/b"))
        #expect(workspace.revealPath == root + "/a/b/c.txt")
        // 列举完成后展平出 a、b、c.txt 三行
        for _ in 0..<50 where workspace.tree.rows.count < 3 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(workspace.tree.rows.map(\.entry.name) == ["a", "b", "c.txt"])
    }

    @Test("根目录之外的路径不会被定位")
    func revealIgnoresOutsidePaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = IDEWorkspace(model: IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: root)))
        workspace.reveal("/etc/hosts")
        #expect(workspace.revealPath == nil)
    }

    @Test("打开文件落到窗口模型标签上")
    func openGoesToModel() throws {
        let workspace = IDEWorkspace(model: IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: "/tmp")))
        workspace.open("/tmp/x.swift", preview: false)
        #expect(workspace.model.activeFilePath == "/tmp/x.swift")
    }

    @Test("关闭未修改的标签直接关闭并可重新打开")
    func closeAndReopen() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = IDEWorkspace(model: IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: root)))
        let id = workspace.model.openFile(root + "/a/b/c.txt", preview: false)
        workspace.requestClose(id ?? UUID())
        #expect(workspace.model.openFilePaths.isEmpty)
        workspace.reopenClosed()
        #expect(workspace.model.openFilePaths == [root + "/a/b/c.txt"])
    }

    @Test("固定标签不会被普通关闭关掉,显式关闭才行")
    func pinnedTabsSurviveClose() {
        let workspace = IDEWorkspace(model: IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: "/tmp")))
        let id = workspace.model.openFile("/tmp/p.swift", preview: false) ?? UUID()
        var layout = workspace.model.editor
        layout.togglePinned(id)
        workspace.model.editor = layout
        workspace.requestClose(id)
        #expect(workspace.model.openFilePaths.count == 1)
        workspace.requestClose(id, force: true)
        #expect(workspace.model.openFilePaths.isEmpty)
    }

    @Test("循环切换标签首尾相接")
    func cycleTabs() {
        let workspace = IDEWorkspace(model: IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: "/tmp")))
        for name in ["a", "b", "c"] { workspace.model.openFile("/tmp/\(name).swift", preview: false) }
        #expect(workspace.model.activeFilePath == "/tmp/c.swift")
        workspace.cycleTab(by: 1)
        #expect(workspace.model.activeFilePath == "/tmp/a.swift")
        workspace.cycleTab(by: -1)
        #expect(workspace.model.activeFilePath == "/tmp/c.swift")
    }

    @Test("没有未保存文件时允许关闭窗口")
    func windowCloseWithoutDirty() {
        let workspace = IDEWorkspace(model: IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: "/tmp")))
        workspace.model.openFile("/tmp/clean.swift", preview: false)
        #expect(workspace.dirtyPaths.isEmpty)
        #expect(workspace.confirmWindowClose())
    }

    @Test("标签拖动字符串可往返编码")
    func tabTransferRoundTrip() {
        let id = UUID()
        #expect(IDETabTransfer.decode(IDETabTransfer.encode(id)) == id)
        #expect(IDETabTransfer.decode("oma-tab:不是 uuid") == nil)
        #expect(IDETabTransfer.decode("其他文本") == nil)
    }
}
