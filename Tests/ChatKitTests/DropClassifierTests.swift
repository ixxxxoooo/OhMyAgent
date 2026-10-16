// @author ixxxxoooo
// 拖入分流与 @ 路径提及的测试。

import Foundation
import Testing

@testable import ChatKit

@Suite("拖入分流")
struct DropClassifierTests {
    /// 建一个带文件、图片、文件夹的临时工作区。
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("src/App.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("a b.txt"), atomically: true, encoding: .utf8)
        try Data([0x89]).write(to: root.appendingPathComponent("pic.PNG"))
        return root
    }

    @Test("按扩展名与目录分类并去重")
    func classify() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = [
            root.appendingPathComponent("src/App.swift"),
            root.appendingPathComponent("pic.PNG"),
            root.appendingPathComponent("src"),
            root.appendingPathComponent("src/App.swift"),
            root.appendingPathComponent("不存在.txt"),
            URL(string: "https://example.com/a.png") ?? root,
        ]
        let items = DropClassifier.classify(urls)
        #expect(items.map(\.kind) == [.file, .image, .directory])
    }

    @Test("工作区内用相对路径,含空白加引号,目录以斜杠结尾")
    func mentionText() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let items = DropClassifier.classify([
            root.appendingPathComponent("src/App.swift"),
            root.appendingPathComponent("a b.txt"),
            root.appendingPathComponent("src"),
        ])
        let texts = items.map { DropClassifier.mentionText(for: $0, workspace: root) }
        #expect(texts == ["@src/App.swift", "@\"a b.txt\"", "@src/"])
    }

    @Test("工作区外使用绝对路径;图片不生成提及")
    func outsideAndImage() throws {
        let root = try makeWorkspace()
        let other = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let items = DropClassifier.classify([other.appendingPathComponent("src/App.swift"), root.appendingPathComponent("pic.PNG")])
        let text = DropClassifier.mentions(for: items, workspace: root)
        #expect(text == "@\(other.standardizedFileURL.path)/src/App.swift ")
    }

    @Test("提及令牌:支持引号路径,@ 必须在词首")
    func tokens() {
        let tokens = CompletionEngine.mentionTokens(in: "看 @src/a.swift 和 @\"my docs/b c.md\" 以及 a@b.com")
        #expect(tokens == ["src/a.swift", "my docs/b c.md"])
    }

    @Test("提及文件:包含文件夹时可选返回目录")
    func mentionedFiles() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "@src/ @\"a b.txt\" @src/App.swift,"
        #expect(CompletionEngine.mentionedFiles(in: text, workspace: root).count == 2)
        #expect(CompletionEngine.mentionedFiles(in: text, workspace: root, includeDirectories: true).count == 3)
    }
}
