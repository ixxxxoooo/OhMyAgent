// @author ixxxxoooo
// IDE 泄漏测试:窗口控制器、窗口工作区、窗口模型、编辑器视图在关闭/移除后必须能被释放(弱引用归零)。
// 窗口放在屏幕外且不抢焦点;每次让出若干个运行循环轮次,等延迟释放(`Task`/主队列)完成。

import AppKit
import EditorCore
import EditorKit
import IDEKit
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("IDE 泄漏")
struct IDELeakTests {
    /// 让出若干轮运行循环,等待延迟释放。
    private func spin(_ turns: Int) {
        for _ in 0..<turns { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    }

    private func drain(_ turns: Int = 20) async {
        for _ in 0..<max(turns / 5, 1) {
            spin(5)
            await Task.yield()
        }
    }

    private func makeRoot() throws -> String {
        let base = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
        let root = base + "/oma-ide-leak-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "let a = 1\nlet b = 2\n".write(toFile: root + "/a.swift", atomically: true, encoding: .utf8)
        return root
    }

    /// 创建并关闭一个 IDE 窗口,只返回弱引用。
    private func openAndClose(root: String, openFile: Bool) -> (IDEWindowReferences) {
        let model = IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: root))
        var controller: IDEWindowController? = IDEWindowController(model: model, cascadeIndex: 0)
        let references = IDEWindowReferences(controller: controller, workspace: controller?.workspace, model: model)
        if let window = controller?.window {
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            if openFile { model.openFile(root + "/a.swift", preview: false) }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            window.close()
        }
        controller = nil
        return references
    }

    @Test("关闭窗口后控制器、工作区与模型都能释放(含已打开文件)")
    func windowsAreReleased() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for openFile in [false, true] {
            let references = openAndClose(root: root, openFile: openFile)
            await drain()
            #expect(references.controller == nil, "窗口控制器泄漏(openFile=\(openFile))")
            #expect(references.workspace == nil, "窗口工作区泄漏(openFile=\(openFile))")
            #expect(references.model == nil, "窗口模型泄漏(openFile=\(openFile))")
        }
    }

    @Test("反复开关 5 个窗口不残留任何控制器")
    func repeatedOpenClose() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var all: [IDEWindowReferences] = []
        for _ in 0..<5 { all.append(openAndClose(root: root, openFile: true)) }
        await drain(40)
        #expect(all.filter { $0.controller != nil }.isEmpty, "仍有 \(all.filter { $0.controller != nil }.count) 个控制器存活")
        #expect(all.filter { $0.model != nil }.isEmpty)
    }

    @Test("反复切换超出保活预算的标签:存活的编辑器数量不随切换次数增长")
    func tabChurnDoesNotLeakEditors() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var paths: [String] = []
        for index in 0..<16 {
            let path = root + "/f\(index).swift"
            try "let v\(index) = \(index)\n".write(toFile: path, atomically: true, encoding: .utf8)
            paths.append(path)
        }
        let model = IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: root))
        var controller: IDEWindowController? = IDEWindowController(model: model, cascadeIndex: 0)
        controller?.window?.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        controller?.window?.orderFront(nil)
        let baseline = OMEditorView.liveCount
        func cycle(_ rounds: Int) async {
            for round in 0..<rounds {
                for path in paths {
                    model.openFile(path, preview: false)
                    spin(2)
                    controller?.window?.contentView?.layoutSubtreeIfNeeded()
                }
                _ = round
                await Task.yield()
            }
        }
        await cycle(1)
        await drain(40)
        let afterFirst = OMEditorView.liveCount - baseline
        await cycle(4)
        await drain(40)
        let afterMore = OMEditorView.liveCount - baseline
        controller?.window?.close()
        controller = nil
        // 保活预算 10 个标签,允许少量在途;关键是多轮切换后不增长
        #expect(afterFirst >= 1, "测试没有真正挂载编辑器")
        #expect(afterFirst <= 14, "首轮后存活编辑器 \(afterFirst) 个,超过保活预算")
        #expect(afterMore <= afterFirst + 2, "多轮切换后编辑器从 \(afterFirst) 增长到 \(afterMore):卸载的标签没有释放")
        await drain(40)
        #expect(OMEditorView.liveCount - baseline <= 2, "关闭窗口后仍有 \(OMEditorView.liveCount - baseline) 个编辑器存活")
    }

    @Test("结束窗口全部终端:模型与 TerminalStore 都不再持有(关闭窗口时调用,防止 shell 残留)")
    func closeAllTerminalsReleasesStore() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: root))
        let workspace = IDEWorkspace(model: model)
        workspace.newTerminal()
        workspace.newTerminal()
        let ids = workspace.terminalIDs
        #expect(ids.count == 2)
        // 真正创建控制器(会启动 shell),模拟面板显示过
        for id in ids { _ = TerminalStore.shared.controller(for: id, fallbackDirectory: root) }
        #expect(ids.allSatisfy { TerminalStore.shared.controllers[$0] != nil })
        workspace.closeAllTerminals()
        #expect(workspace.terminalIDs.isEmpty)
        #expect(ids.allSatisfy { TerminalStore.shared.controllers[$0] == nil }, "终端控制器仍留在仓库里")
    }

    @Test("原生编辑器视图及其模型、文档从窗口移除后都可释放")
    func editorIsReleased() async {
        weak var weakEditor: OMEditorView?
        weak var weakModel: NativeEditorModel?
        weak var weakDocument: EditorDocument?
        func run() {
            let document = EditorDocument(text: String(repeating: "let value = 1\n", count: 500))
            let model = NativeEditorModel(document: document, language: .swift)
            let editor = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
            weakEditor = editor
            weakModel = model
            weakDocument = document
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            window.contentView = nil
            window.close()
        }
        run()
        await drain(60)
        #expect(weakEditor == nil, "编辑器视图泄漏")
        #expect(weakModel == nil, "编辑器模型泄漏")
        #expect(weakDocument == nil, "文档泄漏")
    }
}

/// 一个 IDE 窗口各部分的弱引用集合。
@MainActor
struct IDEWindowReferences {
    weak var controller: IDEWindowController?
    weak var workspace: IDEWorkspace?
    weak var model: IDEWindowModel?
}
