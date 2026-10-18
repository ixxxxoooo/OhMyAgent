// @author ixxxxoooo
// 会话停靠到底部面板/工具栏:搬入、搬回、关闭与回收。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("会话停靠面板")
struct PanelChatsTests {
    private func makeModel() -> WorkbenchModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oma-pc-\(UUID().uuidString)/w.json")
        return WorkbenchModel(store: WorkbenchStore(fileURL: url), autoConnect: false) { url in SessionModel(workspace: url) }
    }

    @Test("非会话标签不能停靠")
    func rejectsNonChatTab() {
        let model = makeModel()
        let id = model.dock.open(.file(path: "/tmp/a.txt"), title: "a")
        #expect(model.dockChat(tab: id, to: .bottom) == false)
        #expect(model.layout.dockedChats.isEmpty)
    }

    @Test("搬入后标签离开编辑区、面板选中它;搬回后恢复")
    func dockAndUndock() {
        let model = makeModel()
        let id = model.dock.open(.chat(projectID: "/p", slot: "s1"), title: "会话")
        #expect(model.dockChat(tab: id, to: .tools))
        #expect(model.dock.tab(id) == nil)
        let chat = PanelChat(projectID: "/p", slot: "s1", host: .tools)
        #expect(model.activeChat(in: .tools) == chat)
        #expect(model.layout.rightVisible)
        model.undockChat(chat)
        #expect(model.layout.dockedChats.isEmpty)
        #expect(model.dock.tab(for: .chat(projectID: "/p", slot: "s1")) != nil)
    }
}
