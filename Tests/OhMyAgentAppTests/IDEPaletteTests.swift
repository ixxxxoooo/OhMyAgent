// @author ixxxxoooo
// IDE 命令面板(I12):打开/索引、选择文件、执行命令、转到行解析、上下文。

import Foundation
import EditorKit
import IDEKit
import Testing
import WorkbenchKit
@testable import OhMyAgentApp

@MainActor
@Suite("IDE 命令面板")
struct IDEPaletteTests {
    private func makeRoot() throws -> String {
        let base = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
        let root = base + "/oma-ide-palette-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/src/main.swift"))
        try Data("y".utf8).write(to: URL(fileURLWithPath: root + "/README.md"))
        return root
    }

    @Test("打开面板后建立文件索引,按名字模糊选择并在编辑器打开")
    func quickOpenFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = IDEWorkspace(model: IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: root)))
        workspace.openPalette("")
        #expect(workspace.palette.isPresented)
        for _ in 0..<60 where workspace.palette.files.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(Set(workspace.palette.files) == ["src/main.swift", "README.md"])
        workspace.palette.text = "main"
        let items = workspace.palette.items(context: workspace.commandContext, recents: [])
        guard case .file(let match)? = items.first else { Issue.record("应命中 main.swift"); return }
        #expect(match.path == "src/main.swift")
        workspace.choose(items[0])
        #expect(!workspace.palette.isPresented)
        #expect(workspace.model.activeFilePath == root + "/src/main.swift")
        #expect(workspace.openRelativePaths == ["src/main.swift"])
    }

    @Test("命令模式列出命令,执行后记入最近使用")
    func runCommand() {
        let workspace = IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: "/tmp"))
        let space = IDEWorkspace(model: workspace)
        space.openPalette(">")
        let items = space.palette.items(context: space.commandContext, recents: [])
        #expect(!items.isEmpty)
        let before = workspace.sidebarVisible
        space.perform("view.toggleSidebar")
        #expect(workspace.sidebarVisible != before)
        space.palette.recordUse("view.toggleSidebar")
        #expect(space.palette.registry.recent.first == "view.toggleSidebar")
        space.perform("view.problems")
        #expect(workspace.panelTab == .problems && workspace.panelVisible)
        space.perform("view.scm")
        #expect(workspace.sidebarView == .scm)
    }

    @Test("上下文随打开文件变化;转到行模式只产生一行")
    func contextAndLine() {
        let space = IDEWorkspace(model: IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: "/tmp")))
        #expect(space.commandContext.hasFolder && !space.commandContext.hasActiveFile)
        space.open("/tmp/a.swift", preview: false)
        #expect(space.commandContext.hasActiveFile)
        space.palette.text = ":42:3"
        let items = space.palette.items(context: space.commandContext, recents: [])
        #expect(items.count == 1)
        if case .line(let line, let column) = items[0] { #expect(line == 42 && column == 3) } else { Issue.record("应为转到行") }
        space.palette.move(5, count: 1)
        #expect(space.palette.highlighted == 0)
        space.palette.move(-3, count: 4)
        #expect(space.palette.highlighted == 0)
    }

    @Test("状态栏语言名与光标上报")
    func statusBarPieces() {
        #expect(IDEStatusBar.languageName(for: "/a/b.swift") == "Swift")
        #expect(IDEStatusBar.languageName(for: "/a/b.ts") == "TypeScript")
        #expect(IDEStatusBar.languageName(for: "/a/b.unknownext") == String(localized: "纯文本"))
        let space = IDEWorkspace(model: IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: "/tmp")))
        space.fileHost.caret("/tmp/a.swift", EditorCaret(line: 3, column: 5, selectedLength: 0))
        #expect(space.carets["/tmp/a.swift"] == EditorCaret(line: 3, column: 5, selectedLength: 0))
    }
}
