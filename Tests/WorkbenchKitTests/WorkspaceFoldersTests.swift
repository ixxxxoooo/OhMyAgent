// @author ixxxxoooo
// 多文件夹工作区:校验规则、模型增删与会话附加目录传递。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("多文件夹工作区")
struct WorkspaceFoldersTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oma-roots-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("规范化去掉末尾斜杠与 ..;包含判断按目录边界")
    func normalizeAndInside() {
        #expect(WorkspaceFolders.normalize("/tmp/a/../b/") == "/tmp/b")
        #expect(WorkspaceFolders.isInside("/tmp/a/b", of: "/tmp/a"))
        #expect(WorkspaceFolders.isInside("/tmp/a", of: "/tmp/a"))
        #expect(!WorkspaceFolders.isInside("/tmp/ab", of: "/tmp/a"))
    }

    @Test("校验:重复、嵌套、包含、数量上限")
    func validation() {
        let primary = "/w/main"
        func check(_ path: String, existing: [String] = []) -> Result<String, WorkspaceFolderError> {
            WorkspaceFolders.validate(path, primary: primary, existing: existing, requireExists: false)
        }
        #expect(check("/w/other") == .success("/w/other"))
        #expect(check("/w/main/") == .failure(.duplicate))
        #expect(check("/w/main/sub") == .failure(.insideExisting("main")))
        #expect(check("/w", existing: []) == .failure(.containsExisting("main")))
        #expect(check("/w/x", existing: ["/w/x"]) == .failure(.duplicate))
        let many = (0..<WorkspaceFolders.maxExtraFolders).map { "/z/\($0)" }
        #expect(check("/y/new", existing: many) == .failure(.tooMany))
    }

    @Test("不存在的目录与普通文件被拒绝")
    func requiresDirectory() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data([1]).write(to: file)
        #expect(WorkspaceFolders.validate(file.path, primary: "/w/main", existing: []) == .failure(.notDirectory))
        #expect(WorkspaceFolders.validate(dir.appendingPathComponent("none").path, primary: "/w/main", existing: []) == .failure(.notDirectory))
        #expect(WorkspaceFolders.validate(dir.path, primary: "/w/main", existing: []) == .success(WorkspaceFolders.normalize(dir.path)))
    }

    @Test("模型增删文件夹,allRoots 主目录在前,并同步到已有会话")
    func modelAddRemove() throws {
        let main = tempDir(), extra = tempDir()
        defer { try? FileManager.default.removeItem(at: main); try? FileManager.default.removeItem(at: extra) }
        let model = WorkbenchModel(store: WorkbenchStore(fileURL: main.appendingPathComponent("workbench.json")), autoConnect: false) { url in
            SessionModel(workspace: url)
        }
        let id = try #require(model.openProject(main))
        let session = try #require(model.ensureSession(for: id))
        #expect(session.additionalDirectories.isEmpty)
        let added = try #require(try? model.addFolder(extra.path, to: id).get())
        #expect(model.allRoots(of: id) == [id, added])
        #expect(session.additionalDirectories == [added])
        #expect(model.addFolder(extra.path, to: id) == .failure(.duplicate))
        model.removeFolder(added, from: id)
        #expect(model.allRoots(of: id) == [id])
        #expect(session.additionalDirectories.isEmpty)
    }

    @Test("新建会话带上附加目录;引擎不支持该能力时写入系统提示兜底")
    func sessionCarriesDirectories() throws {
        let main = tempDir(), extra = tempDir()
        defer { try? FileManager.default.removeItem(at: main); try? FileManager.default.removeItem(at: extra) }
        let model = WorkbenchModel(store: WorkbenchStore(fileURL: main.appendingPathComponent("workbench.json")), autoConnect: false) { url in
            SessionModel(workspace: url)
        }
        let id = try #require(model.openProject(main))
        _ = model.addFolder(extra.path, to: id)
        let session = try #require(model.ensureSession(for: id))
        #expect(session.additionalDirectories == [WorkspaceFolders.normalize(extra.path)])
        #expect(session.additionalDirectoriesNote?.contains(WorkspaceFolders.normalize(extra.path)) == true)
    }

    @Test("@ 补全索引同时收录附加文件夹(绝对路径)")
    func fileIndexCoversExtraRoots() async throws {
        let main = tempDir(), extra = tempDir()
        defer { try? FileManager.default.removeItem(at: main); try? FileManager.default.removeItem(at: extra) }
        try Data([1]).write(to: main.appendingPathComponent("alpha.txt"))
        try Data([1]).write(to: extra.appendingPathComponent("beta.txt"))
        try FileManager.default.createDirectory(at: extra.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let index = FileIndex()
        await index.prepare(root: main, extraRoots: [extra])
        await index.waitUntilReady()
        let base = extra.standardizedFileURL.path
        #expect(await index.search("alpha") == ["alpha.txt"])
        #expect(await index.search("beta") == [base + "/beta.txt"])
        #expect(await index.searchDirectories("docs") == [base + "/docs"])
    }
}
