// @author ygw
// 真实 sourcekit-lsp 集成测试(本机无工具链时直接跳过;使用临时 SwiftPM 包,不依赖网络与模型)。

import ACPKit
import Foundation
import Testing
@testable import LSPKit

@Suite("sourcekit-lsp 集成")
struct SourceKitIntegrationTests {
    private static let source = """
    public struct Greeter {
        public init() {}
        public func hello(name: String) -> String { "hi " + name }
    }
    public func use() {
        let g = Greeter()
        let n: Int = g.hello(name: "x")
        _ = n
    }

    """

    @Test("真实服务器:类型错误诊断、hover、跳转定义、补全")
    func realServer() async throws {
        let root = NSTemporaryDirectory() + "lsp-it-\(UUID().uuidString)"
        let dir = root + "/Sources/Demo"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.target(name: \"Demo\")])\n"
            .write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
        let path = dir + "/A.swift"
        try Self.source.write(toFile: path, atomically: true, encoding: .utf8)
        guard let launch = LSPServerLocator.locate(.swift, projectRoot: root, workspaceRoot: root) else { return }

        let client = LSPClient(transport: LSPStdioTransport(launch: launch), rootPath: root, label: "swift-real", requestTimeout: .seconds(30))
        try await client.start()
        let uri = LSPURI.make(path: path)
        let updates = await client.diagnosticUpdates()
        await client.didOpen(uri: uri, languageID: "swift", text: Self.source)

        // 等到出现非空诊断;看门狗 60 秒后关闭客户端使诊断流结束,避免服务器无响应时卡死
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(60))
            await client.shutdown()
        }
        defer { watchdog.cancel() }
        var found: LSPDiagnosticsUpdate?
        for await update in updates where update.uri == uri && !update.diagnostics.isEmpty {
            found = update
            break
        }
        #expect(found?.diagnostics.first?.range.start.line == 6)
        #expect(found?.diagnostics.first?.message.contains("Int") == true)

        let hover = try await client.hover(uri: uri, at: LSPPosition(line: 5, character: 14))
        #expect(hover?.contains("Greeter") == true)
        let defs = try await client.definition(uri: uri, at: LSPPosition(line: 5, character: 14))
        #expect(defs.first?.range.start.line == 0)
        let comps = try await client.completion(uri: uri, at: LSPPosition(line: 6, character: 22))
        #expect(comps.contains { $0.label.hasPrefix("hello") })
        await client.shutdown()
    }
}
