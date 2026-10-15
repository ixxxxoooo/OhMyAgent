// @author ygw
// 编辑器与语言服务器桥接测试:位置换算、诊断渲染、补全过滤、控制器端到端(脚本化服务器,不依赖真实工具链)。

import ACPKit
import AppKit
import EditorKit
import Foundation
import LSPKit
import Synchronization
import Testing

@testable import OhMyAgentApp

@Suite("LSP 位置换算")
struct LSPTextMappingTests {
    @Test("偏移与位置互转(含多行与行尾)")
    func roundTrip() {
        let index = LineIndex(text: "ab\ncde\n\nf")
        #expect(LSPTextMapping.position(offset: 0, in: index) == LSPPosition(line: 0, character: 0))
        #expect(LSPTextMapping.position(offset: 4, in: index) == LSPPosition(line: 1, character: 1))
        #expect(LSPTextMapping.position(offset: 7, in: index) == LSPPosition(line: 2, character: 0))
        #expect(LSPTextMapping.position(offset: 9, in: index) == LSPPosition(line: 3, character: 1))
        for offset in 0...index.length {
            #expect(LSPTextMapping.offset(of: LSPTextMapping.position(offset: offset, in: index), in: index) == offset)
        }
    }

    @Test("UTF-16:emoji 占两个代码单元")
    func utf16() {
        let text = "a😀b\nx"
        let index = LineIndex(text: text)
        // a(0) 😀(1,2) b(3)
        #expect(LSPTextMapping.position(offset: 3, in: index) == LSPPosition(line: 0, character: 3))
        #expect(LSPTextMapping.offset(of: LSPPosition(line: 0, character: 3), in: index) == 3)
    }

    @Test("越界夹取:列越界到行尾(不含换行),行越界到文末,负数到 0")
    func clamping() {
        let index = LineIndex(text: "ab\ncd")
        #expect(LSPTextMapping.offset(of: LSPPosition(line: 0, character: 99), in: index) == 2)
        #expect(LSPTextMapping.offset(of: LSPPosition(line: 9, character: 0), in: index) == 5)
        #expect(LSPTextMapping.offset(of: LSPPosition(line: -1, character: 3), in: index) == 0)
        #expect(LSPTextMapping.offset(of: LSPPosition(line: 1, character: -2), in: index) == 3)
        #expect(LSPTextMapping.position(offset: 999, in: index) == LSPPosition(line: 1, character: 2))
    }

    @Test("诊断转换:级别、范围与来源")
    func diagnosticConversion() {
        let index = LineIndex(text: "let a = 1\nlet b = a")
        let items = [
            LSPDiagnostic(range: LSPRange(start: .init(line: 1, character: 8), end: .init(line: 1, character: 9)), severity: .warning, message: "w", source: "swift"),
            LSPDiagnostic(range: LSPRange(start: .init(line: 0, character: 4), end: .init(line: 0, character: 4)), message: "e"),
        ]
        let converted = LSPTextMapping.editorDiagnostics(items, in: index)
        #expect(converted[0] == EditorDiagnostic(range: NSRange(location: 18, length: 1), severity: .warning, message: "w  (swift)"))
        #expect(converted[1].severity == .error)
        #expect(converted[1].range == NSRange(location: 4, length: 0))
    }
}

@MainActor
@Suite("编辑器诊断渲染")
struct EditorDiagnosticsRenderTests {
    private func underlined(_ view: CodeEditorView, at index: Int) -> Bool {
        guard let storage = view.textView.textStorage, index < storage.length else { return false }
        return storage.attribute(.underlineStyle, at: index, effectiveRange: nil) != nil
    }

    @Test("诊断范围被加下划线,重设后旧下划线被清除")
    func underlines() {
        let view = CodeEditorView()
        view.setText("let value = 42\nprint(value)", language: .swift)
        view.setDiagnostics([EditorDiagnostic(range: NSRange(location: 4, length: 5), severity: .error, message: "bad")])
        #expect(underlined(view, at: 4))
        #expect(underlined(view, at: 8))
        #expect(!underlined(view, at: 9))
        view.setDiagnostics([EditorDiagnostic(range: NSRange(location: 15, length: 5), severity: .warning, message: "w")])
        #expect(!underlined(view, at: 4))
        #expect(underlined(view, at: 15))
    }

    @Test("空范围扩展到整个标识符;越界范围被夹取不崩溃")
    func emptyAndOutOfRange() {
        let view = CodeEditorView()
        view.setText("foo bar", language: .plain)
        view.setDiagnostics([
            EditorDiagnostic(range: NSRange(location: 4, length: 0), severity: .error, message: "x"),
            EditorDiagnostic(range: NSRange(location: 500, length: 10), severity: .warning, message: "越界"),
        ])
        #expect(underlined(view, at: 4))
        #expect(underlined(view, at: 6))
        #expect(!underlined(view, at: 3))
        #expect(view.diagnostics.count == 2)
    }

    @Test("装载新文本会清空诊断")
    func setTextClears() {
        let view = CodeEditorView()
        view.setText("abc", language: .plain)
        view.setDiagnostics([EditorDiagnostic(range: NSRange(location: 0, length: 3), severity: .error, message: "x")])
        view.setText("abc", language: .plain)
        #expect(view.diagnostics.isEmpty)
        #expect(!underlined(view, at: 0))
    }

    @Test("补全菜单:前缀过滤(忽略大小写)、去重、数量上限")
    func completionMenu() {
        let items = [
            EditorCompletion(label: "Alpha", insertText: "Alpha"),
            EditorCompletion(label: "alphabet", insertText: "alphabet()"),
            EditorCompletion(label: "beta", insertText: "beta"),
            EditorCompletion(label: "alpha2", insertText: "Alpha"),
        ]
        #expect(EditorTextView.menuStrings(for: items, prefix: "alp") == ["Alpha", "alphabet()"])
        #expect(EditorTextView.menuStrings(for: items, prefix: "").count == 3)
        let many = (0..<200).map { EditorCompletion(label: "item\($0)", insertText: "item\($0)") }
        #expect(EditorTextView.menuStrings(for: many, prefix: "item").count == 60)
    }

    @Test("Markdown 围栏被去掉,保留代码与说明")
    func plainTextFromMarkdown() {
        #expect(CodeEditorView.plainText(fromMarkdown: "```swift\nlet x: Int\n```\n\n说明") == "let x: Int\n\n说明")
    }
}

/// 应用层测试用的脚本化语言服务器。
private final class MiniLSPServer: ACPRequestHandler, @unchecked Sendable {
    let changes = Mutex<[String]>([])
    private let connection: ACPConnection

    init(transport: any ACPTransport) async throws {
        connection = ACPConnection(transport: transport, label: "mini-lsp")
        await connection.setRequestHandler(self)
        try await connection.start()
        let inbound = connection.inbound
        Task { [weak self] in
            for await event in inbound {
                guard let self, case .notification(let method, let params) = event else { continue }
                if method == "textDocument/didOpen" || method == "textDocument/didChange" {
                    let text = params?["textDocument"]?["text"]?.stringValue ?? params?["contentChanges"]?.arrayValue?.first?["text"]?.stringValue ?? ""
                    if method == "textDocument/didChange" { self.changes.withLock { $0.append(text) } }
                    await self.connection.notify("textDocument/publishDiagnostics", params: [
                        "uri": params?["textDocument"]?["uri"] ?? .null,
                        "diagnostics": [["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]],
                                         "severity": 1, "message": .string("长度 \(text.utf16.count)")]],
                    ])
                }
            }
        }
    }

    func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case "initialize": return ["capabilities": [:]]
        case "shutdown": return .null
        case "textDocument/hover":
            let line = params?["position"]?["line"]?.intValue ?? -1
            let col = params?["position"]?["character"]?.intValue ?? -1
            return ["contents": .string("hover \(line):\(col)")]
        case "textDocument/definition":
            return [["uri": "file:///tmp/other.swift", "range": ["start": ["line": 8, "character": 0], "end": ["line": 8, "character": 3]]]]
        case "textDocument/completion":
            return [["label": "beta", "sortText": "2"], ["label": "alpha", "sortText": "1"]]
        default: throw JSONRPCError(code: JSONRPCError.methodNotFound, message: method)
        }
    }
}

/// 持有脚本化服务器(Mutex 不可复制,用类包装后才能被闭包捕获)。
private final class ServerBox: Sendable {
    let value = Mutex<MiniLSPServer?>(nil)
}

@MainActor
@Suite("编辑器 LSP 控制器")
struct EditorLSPControllerTests {
    private func makeController(server: ServerBox) -> EditorLSPController {
        let manager = LSPManager(factory: { _, _, _ in
            let (clientSide, serverSide) = LoopbackTransport.makePair()
            Task { if let made = try? await MiniLSPServer(transport: serverSide) { server.value.withLock { $0 = made } } }
            return clientSide
        }, idleTimeout: .seconds(60), failureBackoff: 0.2)
        return EditorLSPController(path: "/tmp/ctl/main.swift", projectRoot: "/tmp/ctl", manager: manager)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("附加后就绪并收到诊断;文本变更防抖后整篇同步")
    func attachAndSync() async throws {
        let server = ServerBox()
        let controller = makeController(server: server)
        await controller.attach(text: "let a = 1")
        #expect(controller.status == .ready("sourcekit-lsp"))
        await waitUntil { !controller.diagnostics.isEmpty }
        #expect(controller.diagnostics.first?.message == "长度 9")
        #expect(controller.errorCount == 1)
        controller.textChanged("let a = 12")
        controller.textChanged("let a = 123")
        await waitUntil { controller.diagnostics.first?.message == "长度 11" }
        #expect(controller.diagnostics.first?.message == "长度 11")
        // 连续两次变更被合并为一次同步
        #expect(server.value.withLock { $0?.changes.withLock { $0 } } == ["let a = 123"])
        controller.detach()
        #expect(controller.status == .off)
    }

    @Test("hover 查询前会先同步最新文本,位置按 UTF-16 换算")
    func hoverFlushesPendingText() async throws {
        let server = ServerBox()
        let controller = makeController(server: server)
        await controller.attach(text: "x")
        let features = controller.features
        controller.textChanged("a\n😀bc")
        let text = await features.hover?(5)
        // 偏移 5:第二行 😀(2 个 UTF-16 单位)+ b 之后 → 第 1 行第 3 列
        #expect(text == "hover 1:3")
        #expect(server.value.withLock { $0?.changes.withLock { $0 } } == ["a\n😀bc"])
        controller.detach()
    }

    @Test("补全按 sortText 排序;跳转定义回调给出路径与 1 起始行号")
    func completionAndDefinition() async throws {
        let server = ServerBox()
        let controller = makeController(server: server)
        let opened = Mutex<(String, Int)?>(nil)
        controller.openLocation = { path, line in opened.withLock { $0 = (path, line) } }
        await controller.attach(text: "abc")
        let items = await controller.features.completion?(1) ?? []
        #expect(items.map(\.label) == ["alpha", "beta"])
        controller.features.definition?(1)
        await waitUntil { opened.withLock { $0 } != nil }
        #expect(opened.withLock { $0?.0 } == "/tmp/other.swift")
        #expect(opened.withLock { $0?.1 } == 9)
        controller.detach()
    }

    @Test("服务器不可用时状态为 unavailable,特性回调为空实现")
    func unavailable() async {
        let manager = LSPManager(factory: { _, _, _ in nil })
        let controller = EditorLSPController(path: "/tmp/ctl/a.py", projectRoot: "/tmp/ctl", manager: manager)
        await controller.attach(text: "x = 1")
        if case .unavailable = controller.status {} else { Issue.record("应为 unavailable: \(controller.status)") }
        #expect(controller.features.hover == nil)
        #expect(!EditorLSPController.isSupported(path: "/a/readme.md"))
    }
}

@Suite("选区引用")
struct EditorReferenceTests {
    private let text = "line 1\nline 2\nline 3\nline 4\n"

    @Test("单行与多行选区生成行范围;结尾换行不多算一行")
    func tokenLines() {
        let ns = text as NSString
        let line2 = ns.range(of: "line 2")
        #expect(EditorReference.token(path: "/p/Sources/A.swift", projectRoot: "/p", text: text, range: line2) == "@Sources/A.swift:2")
        let twoLines = NSRange(location: ns.range(of: "line 2").location, length: ns.range(of: "line 3").upperBound - ns.range(of: "line 2").location)
        #expect(EditorReference.token(path: "/p/Sources/A.swift", projectRoot: "/p", text: text, range: twoLines) == "@Sources/A.swift:2-3")
        let withNewline = NSRange(location: ns.range(of: "line 2").location, length: 7)   // "line 2\n"
        #expect(EditorReference.token(path: "/p/Sources/A.swift", projectRoot: "/p", text: text, range: withNewline) == "@Sources/A.swift:2")
    }

    @Test("项目外文件使用绝对路径")
    func outsideProject() {
        #expect(EditorReference.token(path: "/other/x.txt", projectRoot: "/p", text: text, range: NSRange(location: 0, length: 4)) == "@/other/x.txt:1")
        // 前缀相同但不是子目录
        #expect(EditorReference.token(path: "/project2/x.txt", projectRoot: "/project", text: text, range: NSRange(location: 0, length: 1)) == "@/project2/x.txt:1")
    }

    @Test("追加到草稿:按需补空格,以空格结尾")
    func appendToDraft() {
        #expect(EditorReference.appending("@a:1", to: "") == "@a:1 ")
        #expect(EditorReference.appending("@a:1", to: "解释一下") == "解释一下 @a:1 ")
        #expect(EditorReference.appending("@b:2", to: "看 @a:1 ") == "看 @a:1 @b:2 ")
        #expect(EditorReference.appending("@b:2", to: "第一行\n") == "第一行\n@b:2 ")
    }
}
