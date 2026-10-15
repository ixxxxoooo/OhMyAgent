// @author ygw
// 文件文档仓库测试:载入、编辑脏标记、保存、外部修改(自动刷新/冲突)、只读限制。

import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("文件文档")
struct FileDocumentTests {
    private func tempFile(_ content: String) throws -> String {
        let path = NSTemporaryDirectory() + "oma-doc-\(UUID().uuidString).txt"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// 等待文档载入完成。
    private func loaded(_ doc: FileDocument) async {
        for _ in 0..<100 where doc.text == nil && doc.loadError == nil { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("载入、编辑后变脏、保存后干净并写入磁盘")
    func editAndSave() async throws {
        let path = try tempFile("hello\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = FileDocumentStore()
        let doc = store.document(for: path)
        await loaded(doc)
        #expect(doc.text == "hello\n")
        #expect(!doc.isDirty)
        doc.text = "hello world\n"
        #expect(doc.isDirty)
        #expect(store.dirtyDocuments.count == 1)
        #expect(await store.save(path))
        #expect(!doc.isDirty)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "hello world\n")
    }

    @Test("撤回到原文后不再算脏")
    func revertClean() async throws {
        let path = try tempFile("a")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = FileDocumentStore()
        let doc = store.document(for: path)
        await loaded(doc)
        doc.text = "ab"; #expect(doc.isDirty)
        doc.text = "a"; #expect(!doc.isDirty)
    }

    @Test("外部修改:无本地编辑时自动刷新")
    func externalRefresh() async throws {
        let path = try tempFile("v1")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = FileDocumentStore()
        let doc = store.document(for: path)
        await loaded(doc)
        try await Task.sleep(for: .milliseconds(1100))
        try "v2".write(toFile: path, atomically: true, encoding: .utf8)
        await store.checkExternalChange(path)
        #expect(doc.text == "v2")
        #expect(!doc.externalChange)
    }

    @Test("外部修改:有本地编辑时标记冲突且不覆盖")
    func externalConflict() async throws {
        let path = try tempFile("v1")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = FileDocumentStore()
        let doc = store.document(for: path)
        await loaded(doc)
        doc.text = "mine"
        try await Task.sleep(for: .milliseconds(1100))
        try "theirs".write(toFile: path, atomically: true, encoding: .utf8)
        await store.checkExternalChange(path)
        #expect(doc.externalChange)
        #expect(doc.text == "mine")
        await store.reload(path)
        #expect(doc.text == "theirs")
        #expect(!doc.externalChange && !doc.isDirty)
    }

    @Test("不存在或非 UTF-8 的文件给出错误")
    func unreadable() async throws {
        let store = FileDocumentStore()
        let missing = store.document(for: "/不存在/文件.txt")
        await loaded(missing)
        #expect(missing.loadError != nil)
        let path = NSTemporaryDirectory() + "oma-bin-\(UUID().uuidString)"
        try Data([0xFF, 0xFE, 0x00, 0xC3, 0x28]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bin = store.document(for: path)
        await loaded(bin)
        #expect(bin.loadError != nil)
    }
}
