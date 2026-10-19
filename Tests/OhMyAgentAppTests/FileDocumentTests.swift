// @author ixxxxoooo
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

    @Test("中文文件名:打开时文件还不存在,写出后自动载入;再次打开会重新读取")
    func chineseNameAppearsLater() async throws {
        let dir = NSTemporaryDirectory() + "oma-doc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/大数据知识库技术方案.md"
        let store = FileDocumentStore()
        let doc = store.document(for: path)
        await loaded(doc)
        #expect(doc.text == nil && doc.loadError != nil)
        try "# 技术方案\n".write(toFile: path, atomically: true, encoding: .utf8)
        await store.checkExternalChange(path)
        #expect(doc.text == "# 技术方案\n" && doc.loadError == nil)

        // 另一个文档:失败后重新打开(而不是等文件事件)也会重新读取
        let other = dir + "/说明 文档.txt"
        let failed = store.document(for: other)
        await loaded(failed)
        #expect(failed.loadError != nil)
        try "内容".write(toFile: other, atomically: true, encoding: .utf8)
        let reopened = store.document(for: other)
        for _ in 0..<100 where reopened.text == nil { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(reopened.text == "内容")
    }

    @Test("GBK/GB18030 编码的中文文件可读取,保存后仍是原编码")
    func gb18030RoundTrip() async throws {
        let path = NSTemporaryDirectory() + "oma-doc-\(UUID().uuidString)-中文.txt"
        let gbk = try #require("你好,世界".data(using: FileDocumentStore.gb18030))
        try gbk.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = FileDocumentStore()
        let doc = store.document(for: path)
        await loaded(doc)
        #expect(doc.text == "你好,世界")
        doc.text = "你好,中国"
        #expect(await store.save(path))
        let saved = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(String(data: saved, encoding: FileDocumentStore.gb18030) == "你好,中国")
        #expect(String(data: saved, encoding: .utf8) == nil)
        // 二进制内容不猜编码
        #expect(FileDocumentStore.decodeText(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0xFF])) == nil)
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
