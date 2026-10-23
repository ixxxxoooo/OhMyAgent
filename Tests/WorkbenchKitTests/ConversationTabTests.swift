// @author ixxxxoooo
// 每个会话一个标签:新对话新开标签并拥有独立会话,空白标签复用,关闭标签回收会话,旧状态文件可解码。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("会话标签")
struct ConversationTabTests {
    private func makeEnvironment() throws -> (model: WorkbenchModel, root: URL, project: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-conv-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("state/workbench.json"))
        let model = WorkbenchModel(store: store, autoConnect: false) { url in
            let session = SessionModel(workspace: url)
            session.attention = AttentionCenter()
            return session
        }
        let id = try #require(model.openProject(dir))
        return (model, root, id)
    }

    private func chatTabs(_ model: WorkbenchModel) -> [WorkbenchTab] {
        model.dock.allTabs.filter { if case .chat = $0.kind { return true } else { return false } }
    }

    @Test("空白会话标签被复用;有内容后新对话新开标签并拥有独立会话")
    func newConversationOpensTab() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = env.model
        #expect(chatTabs(model).count == 1)
        model.newConversation(in: env.project)
        #expect(chatTabs(model).count == 1)   // 当前会话是空白的,直接复用
        let first = try #require(model.activeSession)
        first.draft = "未发送的草稿"
        model.newConversation(in: env.project)
        #expect(chatTabs(model).count == 2)
        let second = try #require(model.activeSession)
        #expect(second !== first)
        #expect(model.conversations.count == 2)
        #expect(model.projectID(of: second) == env.project)
        model.shutdownAll()
    }

    @Test("外部持有的专属槽位会话不会被回收;释放后才结束")
    func externalHoldKeepsConversation() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = env.model
        let slot = "ide-test0001"
        _ = try #require(model.ensureSession(project: env.project, slot: slot))
        // 未登记持有:任何一次回收都会把没有标签的会话清掉(这正是修复前 IDE 面板会话被误杀/泄漏的原因)
        model.holdConversation(owner: "window-1", project: env.project, slot: slot)
        model.reapConversations()
        #expect(model.conversations[ConversationKey(projectID: env.project, slot: slot)] != nil)
        #expect(model.externalHoldCount == 1)
        model.releaseConversation(owner: "window-1")
        #expect(model.conversations[ConversationKey(projectID: env.project, slot: slot)] == nil)
        #expect(model.externalHoldCount == 0)
        // 重复释放无副作用
        model.releaseConversation(owner: "window-1")
        model.shutdownAll()
    }

    @Test("同一持有者换槽位:旧会话被回收,新会话保留")
    func externalHoldReplacement() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = env.model
        _ = try #require(model.ensureSession(project: env.project, slot: "ide-a"))
        model.holdConversation(owner: "w", project: env.project, slot: "ide-a")
        _ = try #require(model.ensureSession(project: env.project, slot: "ide-b"))
        model.holdConversation(owner: "w", project: env.project, slot: "ide-b")
        #expect(model.conversations[ConversationKey(projectID: env.project, slot: "ide-a")] == nil)
        #expect(model.conversations[ConversationKey(projectID: env.project, slot: "ide-b")] != nil)
        // 空持有者标识被忽略
        model.holdConversation(owner: "", project: env.project, slot: "ide-b")
        #expect(model.externalHoldCount == 1)
        model.releaseConversation(owner: "w")
        model.shutdownAll()
    }

    @Test("同一窗口多个会话槽位:各自持有互不回收,按窗口前缀整体释放")
    func externalHoldMultiSlotPrefixRelease() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = env.model
        for slot in ["ide-a", "ide-b"] {
            _ = try #require(model.ensureSession(project: env.project, slot: slot))
            model.holdConversation(owner: "win-1|\(slot)", project: env.project, slot: slot)
        }
        #expect(model.externalHoldCount == 2)
        #expect(model.conversations[ConversationKey(projectID: env.project, slot: "ide-a")] != nil)
        // 单个槽位关闭:只回收它自己
        model.releaseConversation(owner: "win-1|ide-a")
        #expect(model.conversations[ConversationKey(projectID: env.project, slot: "ide-a")] == nil)
        #expect(model.conversations[ConversationKey(projectID: env.project, slot: "ide-b")] != nil)
        // 窗口关闭:按前缀整体释放;空前缀与不匹配的前缀无副作用
        model.releaseConversations(ownerPrefix: "")
        model.releaseConversations(ownerPrefix: "win-2")
        #expect(model.externalHoldCount == 1)
        model.releaseConversations(ownerPrefix: "win-1")
        #expect(model.externalHoldCount == 0)
        #expect(model.conversations[ConversationKey(projectID: env.project, slot: "ide-b")] == nil)
        model.shutdownAll()
    }

    @Test("关闭会话标签回收对应会话,激活标签后项目当前会话随之切换")
    func closeReapsConversation() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let model = env.model
        let first = try #require(model.activeSession)
        first.draft = "占位"
        model.newConversation(in: env.project)
        let second = try #require(model.activeSession)
        let firstTab = try #require(chatTabs(model).first { model.session(forTab: $0) === first })
        model.activateTab(firstTab.id)
        #expect(model.activeSession === first)
        let secondTab = try #require(chatTabs(model).first { model.session(forTab: $0) === second })
        model.closeTab(secondTab.id)
        #expect(model.conversations.count == 1)
        #expect(model.activeSession === first)
        model.shutdownAll()
    }

    @Test("旧状态文件里没有 slot 字段的会话标签仍可解码为主会话")
    func legacyDecoding() throws {
        let json = #"{"chat":{"projectID":"/p"}}"#
        let kind = try JSONDecoder().decode(TabKind.self, from: Data(json.utf8))
        #expect(kind == .chat(projectID: "/p", slot: nil))
        let encoded = try JSONEncoder().encode(TabKind.chat(projectID: "/p", slot: "abc"))
        #expect(try JSONDecoder().decode(TabKind.self, from: encoded) == .chat(projectID: "/p", slot: "abc"))
    }

    @Test("启动恢复时每个项目只保留一个会话标签")
    func restoreKeepsOneChatTab() {
        var dock = DockLayout()
        dock.open(.chat(projectID: "/tmp", slot: "a"), title: "a")
        dock.open(.chat(projectID: "/tmp", slot: "b"), title: "b")
        let restored = dock.restoredForLaunch(projectIDs: ["/tmp"])
        #expect(restored.allTabs.filter { if case .chat = $0.kind { return true } else { return false } }.count == 1)
    }
}
