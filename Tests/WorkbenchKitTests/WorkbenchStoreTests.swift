// @author ixxxxoooo
// 工作台状态文件:损坏时先备份,不能被随后的保存直接覆盖。

import ChatKit
import Foundation
import Testing

@testable import WorkbenchKit

@Suite("工作台状态文件")
struct WorkbenchStoreTests {
    /// 新建一个临时目录下的状态文件存取器。
    private func makeStore() throws -> (WorkbenchStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-wbstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (WorkbenchStore(fileURL: root.appendingPathComponent("workbench.json")), root)
    }

    @Test("文件不存在时返回 nil 且不产生备份")
    func missingFile() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.corruptBackupURL.path))
    }

    @Test("文件损坏时备份原内容并返回 nil")
    func corruptFileIsBackedUp() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let garbage = Data("{\"projects\": [ 不是 JSON".utf8)
        try garbage.write(to: store.fileURL)
        #expect(store.load() == nil)
        #expect(try Data(contentsOf: store.corruptBackupURL) == garbage)
        // 随后保存默认状态不影响备份
        try store.save(WorkbenchState())
        #expect(try Data(contentsOf: store.corruptBackupURL) == garbage)
    }

    @Test("正常文件往返读取,不产生备份")
    func roundTrip() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = WorkbenchState()
        state.selectedProjectID = "/tmp/demo"
        try store.save(state)
        #expect(store.load()?.selectedProjectID == "/tmp/demo")
        #expect(!FileManager.default.fileExists(atPath: store.corruptBackupURL.path))
    }

    @Test("目录暂时不存在的项目不显示,但保存后仍保留在状态文件中")
    @MainActor
    func unavailableProjectsSurviveSave() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let present = root.appendingPathComponent("present", isDirectory: true)
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("unmounted-volume", isDirectory: true)
        var state = WorkbenchState()
        state.projects = [ProjectEntry(url: present), ProjectEntry(url: missing)]
        try store.save(state)

        let model = WorkbenchModel(store: store, autoConnect: false) { url in SessionModel(workspace: url) }
        #expect(model.projects.map(\.id) == [ProjectEntry(url: present).id])
        model.saveNow()
        let saved = try #require(store.load())
        #expect(Set(saved.projects.map(\.id)) == [ProjectEntry(url: present).id, ProjectEntry(url: missing).id])
    }
}
