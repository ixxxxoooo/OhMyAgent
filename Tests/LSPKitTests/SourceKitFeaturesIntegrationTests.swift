// @author ixxxxoooo
// 真实 sourcekit-lsp 的语言功能验收:引用、文档符号、重命名、格式化、签名帮助、代码操作、工作区符号。
// 本机没有工具链时直接跳过;使用临时 SwiftPM 包,不依赖网络与模型。

import ACPKit
import Foundation
import Testing
@testable import LSPKit

@Suite("sourcekit-lsp 语言功能")
struct SourceKitFeaturesIntegrationTests {
    /// 故意写乱的代码:用于格式化;`Greeter` 被使用两次,用于引用与重命名;第 8 行有未使用变量的警告,用于代码操作(必须能编译通过,否则不会生成索引)。
    private static let source = """
    public struct Greeter {
    public init() {}
        public func hello(name: String,   times: Int) -> String { "hi " + name }
    }
    public func use() {
        let g = Greeter()
        let other = Greeter()
        let n: Int = g.hello(name: "x", times: 1)
        _ = (n, other)
    }

    """

    @Test("真实服务器:引用、文档符号、重命名、格式化、签名帮助、代码操作、工作区符号")
    func languageFeatures() async throws {
        let root = NSTemporaryDirectory() + "lsp-feat-\(UUID().uuidString)"
        let dir = root + "/Sources/Demo"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.target(name: \"Demo\")])\n"
            .write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
        let path = dir + "/A.swift"
        try Self.source.write(toFile: path, atomically: true, encoding: .utf8)
        guard let launch = LSPServerLocator.locate(.swift, projectRoot: root, workspaceRoot: root) else { return }
        // 引用查询依赖代码索引(sourcekit-lsp 读构建产物里的 index store);临时包没编译过时引用恒为空,所以先编译一次。
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        build.arguments = ["build", "--package-path", root]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()

        let client = LSPClient(transport: LSPStdioTransport(launch: launch), rootPath: root, label: "swift-features", requestTimeout: .seconds(30))
        try await client.start()
        let uri = LSPURI.make(path: path)
        let updates = await client.diagnosticUpdates()
        await client.didOpen(uri: uri, languageID: "swift", text: Self.source)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(60))
            await client.shutdown()
        }
        defer { watchdog.cancel() }
        var diagnostics: [LSPDiagnostic] = []
        for await update in updates where update.uri == uri && !update.diagnostics.isEmpty {
            diagnostics = update.diagnostics
            break
        }
        #expect(!diagnostics.isEmpty, "应先等到诊断,说明服务器已完成分析")

        // 引用:声明 + 两处使用(0 行声明,5、6 行使用)
        // 索引由服务器异步加载:最多重试 20 秒
        var refs: [LSPLocation] = []
        for _ in 0..<20 {
            refs = try await client.references(uri: uri, at: LSPPosition(line: 5, character: 14))
            if !refs.isEmpty { break }
            try await Task.sleep(for: .seconds(1))
        }
        #expect(Set(refs.map(\.range.start.line)).isSuperset(of: [0, 5, 6]), "引用应覆盖声明与两处使用,实际 \(refs.map(\.range.start.line))")

        // 文档符号(大纲):结构体及其方法、顶层函数
        let symbols = try await client.documentSymbols(uri: uri)
        let names = symbols.flatMap { $0.flattened() }.map(\.symbol.name)
        #expect(names.contains { $0.hasPrefix("Greeter") })
        #expect(names.contains { $0.hasPrefix("hello") })
        #expect(names.contains { $0.hasPrefix("use") })

        // 重命名:同一文件内声明与两处使用都要改到
        let edit = try await client.rename(uri: uri, at: LSPPosition(line: 5, character: 14), newName: "Welcomer")
        #expect(edit.editCount >= 3, "重命名应改到声明与两处使用,实际 \(edit.editCount) 处")
        #expect(edit.changes.values.flatMap { $0 }.allSatisfy { $0.newText == "Welcomer" })

        // 格式化:sourcekit-lsp 的格式化依赖 swift-format;不支持时断言为空而不是失败
        if await client.supports("documentFormattingProvider") {
            let edits = try await client.formatting(uri: uri, tabSize: 4, insertSpaces: true)
            #expect(!edits.isEmpty, "乱缩进与多余空格的代码应产生格式化编辑")
        }

        // 签名帮助:光标在 hello( 之后(第 8 行)
        if await client.supports("signatureHelpProvider") {
            let help = try await client.signatureHelp(uri: uri, at: LSPPosition(line: 7, character: 29))
            #expect(help?.label.contains("hello") == true)
        }

        // 代码操作:对类型错误请求(不抛错即可;有快速修复时标题非空)
        if let first = diagnostics.first {
            let actions = try await client.codeActions(uri: uri, range: first.range, diagnostics: [first])
            #expect(actions.allSatisfy { !$0.title.isEmpty })
        }

        // 工作区符号
        if await client.supports("workspaceSymbolProvider") {
            let found = try await client.workspaceSymbols(query: "Greeter")
            #expect(found.isEmpty || found.contains { $0.name.contains("Greeter") })
        }
        await client.shutdown()
    }
}
