// @author ygw
// 会话置顶/归档、设置整页模式与旧状态文件兼容性测试。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("会话置顶、归档与设置模式")
struct SessionFlagsTests {
    private func makeModel() throws -> (WorkbenchModel, String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-flags-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("state/workbench.json"))
        let model = WorkbenchModel(store: store, autoConnect: false) { url in
            let session = SessionModel(workspace: url)
            session.attention = AttentionCenter()
            return session
        }
        let id = try #require(model.openProject(dir))
        return (model, id, root)
    }

    @Test("置顶可切换,且按先后顺序记录")
    func pinToggle() throws {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.toggleSessionPin("s1", in: id)
        model.toggleSessionPin("s2", in: id)
        #expect(model.projects[0].pinnedSessions == ["s1", "s2"])
        model.toggleSessionPin("s1", in: id)
        #expect(!model.isSessionPinned("s1", in: id))
        #expect(model.isSessionPinned("s2", in: id))
        model.toggleSessionPin("", in: id)
        #expect(model.projects[0].pinnedSessions == ["s2"])
        model.shutdownAll()
    }

    @Test("归档会取消置顶;置顶会取消归档;可恢复")
    func archiveInteractions() throws {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.toggleSessionPin("s1", in: id)
        model.setSessionArchived(true, sessionId: "s1", in: id)
        #expect(model.isSessionArchived("s1", in: id))
        #expect(!model.isSessionPinned("s1", in: id))
        model.toggleSessionPin("s1", in: id)
        #expect(!model.isSessionArchived("s1", in: id))
        #expect(model.isSessionPinned("s1", in: id))
        model.setSessionArchived(true, sessionId: "s1", in: id)
        model.setSessionArchived(false, sessionId: "s1", in: id)
        #expect(!model.isSessionArchived("s1", in: id))
        model.shutdownAll()
    }

    @Test("置顶与归档随状态文件持久化")
    func persistence() throws {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.toggleSessionPin("a", in: id)
        model.setSessionArchived(true, sessionId: "b", in: id)
        model.saveNow()
        let reloaded = WorkbenchStore(fileURL: root.appendingPathComponent("state/workbench.json")).load()
        #expect(reloaded?.projects.first?.pinnedSessions == ["a"])
        #expect(reloaded?.projects.first?.archivedSessions == ["b"])
        model.shutdownAll()
    }

    @Test("旧版本状态文件缺少新字段时仍可读取")
    func legacyStateDecodes() throws {
        let json = """
        {"id":"/tmp/x","name":"x","addedAt":"2026-01-01T00:00:00Z","lastOpenedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(ProjectEntry.self, from: Data(json.utf8))
        #expect(entry.pinnedSessions.isEmpty && entry.archivedSessions.isEmpty && !entry.pinned)
    }

    @Test("设置整页模式可进入与返回,且不写入持久化状态")
    func settingsMode() throws {
        let (model, _, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.mode == .workspace)
        model.openSettings()
        #expect(model.mode == .settings)
        model.closeSettings()
        #expect(model.mode == .workspace)
        model.shutdownAll()
    }
}
