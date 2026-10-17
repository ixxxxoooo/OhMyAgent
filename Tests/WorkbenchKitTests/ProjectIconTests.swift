// @author ixxxxoooo
// 项目图标:构造、兼容解码、图片导入与模型落盘。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("项目图标")
struct ProjectIconTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oma-icon-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("表情只取第一个字符,空输入无效;符号去空白")
    func constructors() {
        #expect(ProjectIcon.emoji("  🚀🔥")?.value == "🚀")
        #expect(ProjectIcon.emoji("   ") == nil)
        #expect(ProjectIcon.symbol(" rocket ")?.value == "rocket")
        #expect(ProjectIcon.symbol("") == nil)
    }

    @Test("旧状态文件没有 icon / extraFolders 字段也能解码")
    func backwardCompatibleDecoding() throws {
        let json = #"{"id":"/tmp/p","name":"p","addedAt":0,"lastOpenedAt":0}"#
        let entry = try JSONDecoder().decode(ProjectEntry.self, from: Data(json.utf8))
        #expect(entry.icon == nil)
        #expect(entry.extraFolders.isEmpty)
        var withIcon = entry
        withIcon.icon = ProjectIcon.emoji("🍎")
        withIcon.extraFolders = ["/tmp/q"]
        let round = try JSONDecoder().decode(ProjectEntry.self, from: JSONEncoder().encode(withIcon))
        #expect(round.icon == withIcon.icon)
        #expect(round.extraFolders == ["/tmp/q"])
    }

    @Test("导入图片复制到图标目录;非图片与不存在的文件被拒绝")
    func importImage() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("logo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        let target = dir.appendingPathComponent("icons")
        let icon = try #require(ProjectIconFiles.importImage(from: source, into: target))
        #expect(icon.kind == .image)
        #expect(ProjectIconFiles.fileURL(for: icon, in: target) != nil)
        let text = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: text)
        #expect(ProjectIconFiles.importImage(from: text, into: target) == nil)
        #expect(ProjectIconFiles.importImage(from: dir.appendingPathComponent("nope.png"), into: target) == nil)
        ProjectIconFiles.removeFile(for: icon, in: target)
        #expect(ProjectIconFiles.fileURL(for: icon, in: target) == nil)
    }

    @Test("模型设置/恢复图标,替换图片图标时删除旧文件")
    func modelSetAndReset() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = WorkbenchModel(store: WorkbenchStore(fileURL: dir.appendingPathComponent("workbench.json")), autoConnect: false) { url in
            SessionModel(workspace: url)
        }
        guard let id = model.openProject(dir) else { Issue.record("应能打开项目"); return }
        let source = dir.appendingPathComponent("logo.png")
        try Data([1, 2, 3]).write(to: source)
        let image = try #require(model.importProjectIcon(imageAt: source))
        model.setProjectIcon(image, for: id)
        #expect(model.projects.first?.icon == image)
        #expect(ProjectIconFiles.fileURL(for: image, in: model.projectIconDirectory) != nil)
        model.setProjectIcon(ProjectIcon.emoji("🚀"), for: id)
        #expect(ProjectIconFiles.fileURL(for: image, in: model.projectIconDirectory) == nil)
        model.setProjectIcon(nil, for: id)
        #expect(model.projects.first?.icon == nil)
    }
}
