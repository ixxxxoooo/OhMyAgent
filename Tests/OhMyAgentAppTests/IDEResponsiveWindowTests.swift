// @author ixxxxoooo
// IDE 窗口缩放的真实视图验证:挂载真实窗口,按宽度逐档调整,检查编辑区(原生编辑器视图)是否按预期收起 / 恢复。

import AppKit
import EditorKit
import IDEKit
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("IDE 窗口缩放", .serialized)
struct IDEResponsiveWindowTests {
    /// 让出若干轮:既要跑运行循环(显示周期),也要让主 actor 上的任务(读盘、SwiftUI 刷新)有机会执行,所以必须 await。
    private func spin(_ turns: Int = 25) async {
        for _ in 0..<turns {
            NSApp.windows.forEach { $0.displayIfNeeded() }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private func editorViews(in view: NSView?) -> [OMEditorView] {
        guard let view else { return [] }
        return (view as? OMEditorView).map { [$0] } ?? view.subviews.flatMap { editorViews(in: $0) }
    }

    private func hasExplorer(in view: NSView?) -> Bool {
        guard let view else { return false }
        return String(describing: type(of: view)) == "IDEExplorerTable" || view.subviews.contains { hasExplorer(in: $0) }
    }

    @Test("宽度逐档变窄:编辑区在放不下时收起,只剩 Agent 面板;变宽后恢复")
    func editorCollapsesAndRestores() async throws {
        let root = NSTemporaryDirectory() + "oma-ide-resp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "let a = 1\n".write(toFile: root + "/a.swift", atomically: true, encoding: .utf8)
        let model = IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: root))
        model.openFile(root + "/a.swift", preview: false)
        model.sidebarVisible = true
        model.agentPaneVisible = true
        let controller = IDEWindowController(model: model, cascadeIndex: 0)
        let window = try #require(controller.window)
        // 必须在屏幕上(几乎透明、不接收鼠标):屏幕外的窗口不跑显示周期,SwiftUI 不会求值
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.close() }
        // 先等文件载入、编辑器挂载(读盘是异步的)
        window.setContentSize(NSSize(width: 1400, height: 800))
        for _ in 0..<60 where editorViews(in: window.contentView).isEmpty {
            window.contentView?.layoutSubtreeIfNeeded()
            await spin(5)
        }
        var present: [Double: Bool] = [:]
        for width in [1400.0, 900.0, 700.0, 640.0, 560.0, 480.0, 1400.0] {
            window.setContentSize(NSSize(width: width, height: 800))
            window.contentView?.layoutSubtreeIfNeeded()
            await spin()
            window.contentView?.layoutSubtreeIfNeeded()
            let found = !editorViews(in: window.contentView).isEmpty
            if present[width] == nil { present[width] = found }
            let actual = Double(window.contentView?.bounds.width ?? 0)
            #expect(actual >= IDEMetrics.windowMinWidth, "窗口宽度 \(actual) 低于最小宽度")
            // 编辑区所需宽度:活动栏 + 编辑区最小宽 + Agent 面板最小宽
            let needsEditor = actual >= IDEMetrics.activityBarWidth + IDEMetrics.editorMinWidth + IDEMetrics.agentRange.lowerBound
            let needsSidebar = actual >= IDEMetrics.activityBarWidth + IDEMetrics.sidebarRange.lowerBound + IDEMetrics.editorMinWidth + IDEMetrics.agentRange.lowerBound
            #expect(hasExplorer(in: window.contentView) == needsSidebar, "宽 \(actual):侧栏显示状态不对(应\(needsSidebar ? "显示" : "收起"))")
            #expect(found == needsEditor, "宽 \(actual):编辑区\(found ? "存在" : "不存在"),应\(needsEditor ? "存在" : "收起")")
        }
        #expect(present[1400] == true)
        #expect(present[480] == false)
    }

    @Test("切换文件:新编辑器就绪后换到前台,旧编辑器保活,期间始终有编辑器可见")
    func switchingFilesKeepsAnEditorVisible() async throws {
        let root = NSTemporaryDirectory() + "oma-ide-swap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "let a = 1\n".write(toFile: root + "/a.swift", atomically: true, encoding: .utf8)
        try "let bb = 22\nlet cc = 3\n".write(toFile: root + "/b.swift", atomically: true, encoding: .utf8)
        let model = IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: root))
        model.openFile(root + "/a.swift", preview: false)
        let controller = IDEWindowController(model: model, cascadeIndex: 0)
        let window = try #require(controller.window)
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.close() }
        window.setContentSize(NSSize(width: 1200, height: 800))
        for _ in 0..<60 where editorViews(in: window.contentView).isEmpty { await spin(5) }
        #expect(editorViews(in: window.contentView).count == 1)
        model.openFile(root + "/b.swift", preview: false)
        // 切换过程中每一轮都必须至少有一个编辑器挂载(旧的保留到新的就绪)
        var minimum = Int.max
        for _ in 0..<40 {
            await spin(1)
            minimum = min(minimum, editorViews(in: window.contentView).count)
        }
        #expect(minimum >= 1, "切换期间出现了没有编辑器的空窗")
        let lines = Set(editorViews(in: window.contentView).map { $0.model.document.lineCount })
        #expect(lines.contains(3), "新文件没有挂载(行数集合 \(lines))")
    }
}
