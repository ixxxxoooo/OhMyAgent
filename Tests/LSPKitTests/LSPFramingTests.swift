// @author ixxxxoooo
// LSP 分帧、响应解析、服务器定位测试。

import ACPKit
import Foundation
import Testing
@testable import LSPKit

@Suite("LSP 分帧")
struct LSPFramingTests {
    private func frame(_ json: String) -> Data { LSPFrameEncoder.encode(Data(json.utf8)) }

    @Test("编码带 Content-Length(按字节而非字符)")
    func encodeUsesByteLength() {
        let body = Data("{\"a\":\"中文\"}".utf8)
        let text = String(decoding: LSPFrameEncoder.encode(body), as: UTF8.self)
        #expect(text.hasPrefix("Content-Length: \(body.count)\r\n\r\n"))
        #expect(body.count > "{\"a\":\"中文\"}".count)
    }

    @Test("一次读取包含多帧")
    func multipleFramesInOneChunk() {
        var decoder = LSPFrameDecoder()
        var chunk = frame("{\"id\":1}")
        chunk.append(frame("{\"id\":2}"))
        let bodies = decoder.push(chunk)
        #expect(bodies.map { String(decoding: $0, as: UTF8.self) } == ["{\"id\":1}", "{\"id\":2}"])
    }

    @Test("头部与正文被任意拆分(逐字节喂入)")
    func byteByByte() {
        var decoder = LSPFrameDecoder()
        let data = frame("{\"msg\":\"你好,世界\"}")
        var out: [Data] = []
        for byte in data { out += decoder.push(Data([byte])) }
        #expect(out.count == 1)
        #expect(String(decoding: out[0], as: UTF8.self) == "{\"msg\":\"你好,世界\"}")
    }

    @Test("多余头部与大小写不敏感的 Content-Length")
    func extraHeaders() {
        var decoder = LSPFrameDecoder()
        let body = "{\"x\":1}"
        let raw = "content-length: \(body.utf8.count)\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n\(body)"
        #expect(decoder.push(Data(raw.utf8)).count == 1)
    }

    @Test("非法头部被丢弃后能与后续帧重新同步")
    func resyncAfterGarbage() {
        var decoder = LSPFrameDecoder()
        var chunk = Data("garbage line\r\n\r\n".utf8)
        chunk.append(frame("{\"ok\":true}"))
        let bodies = decoder.push(chunk)
        #expect(bodies.count == 1)
        #expect(decoder.droppedCount == 1)
    }

    @Test("超大正文长度被拒绝")
    func oversizedRejected() {
        var decoder = LSPFrameDecoder(maxBodyLength: 10)
        let bodies = decoder.push(Data("Content-Length: 999\r\n\r\n".utf8))
        #expect(bodies.isEmpty)
        #expect(decoder.droppedCount == 1)
    }
}

@Suite("LSP 响应解析")
struct LSPDecodeTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test("定义:Location / Location[] / LocationLink[]")
    func locations() throws {
        let range = "{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":1,\"character\":5}}"
        let single = LSPDecode.locations(try json("{\"uri\":\"file:///a.swift\",\"range\":\(range)}"))
        #expect(single == [LSPLocation(uri: "file:///a.swift", range: LSPRange(start: .init(line: 1, character: 2), end: .init(line: 1, character: 5)))])
        let array = LSPDecode.locations(try json("[{\"uri\":\"file:///a\",\"range\":\(range)},{\"uri\":\"file:///b\",\"range\":\(range)}]"))
        #expect(array.map(\.uri) == ["file:///a", "file:///b"])
        let link = LSPDecode.locations(try json("[{\"targetUri\":\"file:///t\",\"targetRange\":\(range),\"targetSelectionRange\":\(range)}]"))
        #expect(link.first?.uri == "file:///t")
        #expect(LSPDecode.locations(.null).isEmpty)
    }

    @Test("hover:MarkupContent / MarkedString / 数组 / 空")
    func hover() throws {
        #expect(LSPDecode.hoverText(try json("{\"contents\":{\"kind\":\"markdown\",\"value\":\"```swift\\nlet x\\n```\"}}")) == "```swift\nlet x\n```")
        #expect(LSPDecode.hoverText(try json("{\"contents\":\"plain\"}")) == "plain")
        #expect(LSPDecode.hoverText(try json("{\"contents\":[\"a\",{\"language\":\"ts\",\"value\":\"b\"}]}")) == "a\n\nb")
        #expect(LSPDecode.hoverText(try json("{\"contents\":\"  \"}")) == nil)
        #expect(LSPDecode.hoverText(.null) == nil)
    }

    @Test("补全:列表/数组、textEdit 优先、片段去占位符")
    func completions() throws {
        let list = try json("{\"isIncomplete\":false,\"items\":[{\"label\":\"foo\",\"kind\":3,\"detail\":\"() -> Void\"},{\"label\":\"bar\",\"insertText\":\"bar($1)\",\"insertTextFormat\":2},{\"label\":\"baz\",\"textEdit\":{\"newText\":\"bazz\",\"range\":{}}},{\"label\":\"\"}]}")
        let items = LSPDecode.completions(list)
        #expect(items.map(\.label) == ["foo", "bar", "baz"])
        #expect(items[0].insertText == "foo")
        #expect(items[1].insertText == "bar()")
        #expect(items[2].insertText == "bazz")
        #expect(LSPDecode.completions(try json("[{\"label\":\"x\"}]")).count == 1)
    }

    @Test("片段语法:命名占位符与转义")
    func snippetStripping() {
        #expect(LSPDecode.stripSnippet("f(${1:name}, ${2:value})$0") == "f(name, value)")
        #expect(LSPDecode.stripSnippet("a\\$b") == "a$b")
        #expect(LSPDecode.stripSnippet("cost $") == "cost $")
    }

    @Test("诊断缺省严重程度按错误处理")
    func severityDefault() throws {
        let d = try json("{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"message\":\"m\"}").decode(LSPDiagnostic.self)
        #expect(d.effectiveSeverity == .error)
    }

    @Test("URI 与路径互转(含空格与中文)")
    func uriRoundTrip() {
        let path = "/tmp/my dir/文件.swift"
        let uri = LSPURI.make(path: path)
        #expect(uri.hasPrefix("file:///"))
        #expect(!uri.contains(" "))
        #expect(LSPURI.path(from: uri) == path)
        #expect(LSPURI.path(from: "https://x.com/a") == nil)
    }
}

@Suite("LSP 服务器定位")
struct LSPServersTests {
    @Test("按扩展名识别服务器与 languageId")
    func kinds() {
        #expect(LSPServerKind.kind(forPath: "/a/b.swift") == .swift)
        #expect(LSPServerKind.kind(forPath: "/a/b.tsx") == .typescript)
        #expect(LSPServerKind.languageID(forPath: "/a/b.tsx") == "typescriptreact")
        #expect(LSPServerKind.kind(forPath: "/a/b.JS") == .typescript)
        #expect(LSPServerKind.kind(forPath: "/a/b.py") == .python)
        #expect(LSPServerKind.kind(forPath: "/a/b.go") == .go)
        #expect(LSPServerKind.languageID(forPath: "/a/b.go") == "go")
        #expect(LSPServerKind.kind(forPath: "/a/b.rs") == nil)
    }

    @Test("Go:定位 ~/go/bin 下的 gopls,工作区根取 go.mod 所在目录")
    func goServer() {
        let launch = LSPServerLocator.locate(.go, projectRoot: "/p", workspaceRoot: "/p", environment: ["PATH": "/usr/bin"], home: "/h", isExecutable: { $0 == "/h/go/bin/gopls" })
        #expect(launch?.executable == "/h/go/bin/gopls")
        #expect(launch?.arguments == [])
        let exists: (String) -> Bool = { $0 == "/p/svc/go.mod" }
        #expect(LSPServerLocator.workspaceRoot(for: "/p/svc/a/b.go", kind: .go, projectRoot: "/p", fileExists: exists) == "/p/svc")
    }

    @Test("工作区根:向上查找标记且不越过项目根")
    func workspaceRoot() {
        let existing: Set<String> = ["/p/Package.swift", "/p/sub/pkg/Package.swift", "/outside/Package.swift"]
        let exists: (String) -> Bool = { existing.contains($0) }
        #expect(LSPServerLocator.workspaceRoot(for: "/p/sub/pkg/Sources/A.swift", kind: .swift, projectRoot: "/p", fileExists: exists) == "/p/sub/pkg")
        #expect(LSPServerLocator.workspaceRoot(for: "/p/x/B.swift", kind: .swift, projectRoot: "/p", fileExists: exists) == "/p")
        // 项目内无标记 → 项目根
        #expect(LSPServerLocator.workspaceRoot(for: "/p/x/y.ts", kind: .typescript, projectRoot: "/p", fileExists: exists) == "/p")
        // 文件不在项目内 → 所在目录(不向上越界)
        #expect(LSPServerLocator.workspaceRoot(for: "/outside/deep/C.swift", kind: .swift, projectRoot: "/p", fileExists: exists) == "/outside/deep")
    }

    @Test("定位:项目本地 node_modules 优先,并补全 PATH")
    func locatePrefersLocal() {
        let local = "/proj/node_modules/.bin/typescript-language-server"
        let global = "/opt/homebrew/bin/typescript-language-server"
        let launch = LSPServerLocator.locate(.typescript, projectRoot: "/proj", workspaceRoot: "/proj", environment: ["PATH": "/usr/bin"], home: "/nonexistent-home", isExecutable: { $0 == local || $0 == global })
        #expect(launch?.executable == local)
        #expect(launch?.arguments == ["--stdio"])
        #expect(launch?.workingDirectory == "/proj")
        #expect(launch?.environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    @Test("定位:找不到返回 nil;python 回退 basedpyright")
    func locateMissingAndFallback() {
        #expect(LSPServerLocator.locate(.swift, projectRoot: "/p", workspaceRoot: "/p", environment: [:], home: "/nonexistent-home", isExecutable: { _ in false }) == nil)
        let launch = LSPServerLocator.locate(.python, projectRoot: "/p", workspaceRoot: "/p", environment: ["PATH": "/x"], home: "/nonexistent-home", isExecutable: { $0 == "/x/basedpyright-langserver" })
        #expect(launch?.executable == "/x/basedpyright-langserver")
    }
}
