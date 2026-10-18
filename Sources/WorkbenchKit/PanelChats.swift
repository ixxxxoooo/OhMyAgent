// @author ixxxxoooo
// 会话停靠到底部面板/工具栏:把编辑区里的会话标签搬进面板标签条,也能搬回编辑区。无视图。

import Foundation

/// 停靠在面板里的会话(对应一个会话槽位)。
public struct PanelChat: Hashable, Identifiable, Sendable {
    public var projectID: String
    public var slot: String?
    /// 所在面板
    public var host: PanelChatHost

    public var id: String { "\(host.rawValue)|\(projectID)|\(slot ?? "-")" }

    public init(projectID: String, slot: String?, host: PanelChatHost) {
        self.projectID = projectID
        self.slot = slot
        self.host = host
    }
}

/// 会话可停靠的面板。
public enum PanelChatHost: String, Sendable {
    /// 底部面板标签条(终端/输出旁)
    case bottom
    /// 工具栏图标条(文件/搜索/Git 旁)
    case tools
}

@MainActor
public extension WorkbenchModel {
    /// 把编辑区的会话标签搬进面板。
    /// - Parameters:
    ///   - tabID: 会话标签 ID
    ///   - host: 目标面板
    /// - Returns: 是否生效;标签不是会话标签时为 false
    @discardableResult
    func dockChat(tab tabID: UUID, to host: PanelChatHost) -> Bool {
        guard let tab = dock.tab(tabID), case .chat(let projectID, let slot) = tab.kind else { return false }
        let chat = PanelChat(projectID: projectID, slot: slot, host: host)
        if !layout.dockedChats.contains(chat) { layout.dockedChats.append(chat) }
        select(chat)
        // 先登记再关标签,会话不会被回收
        dock.close(tabID)
        return true
    }

    /// 选中面板里的会话(并让面板显示出来)。
    /// - Parameter chat: 面板会话
    func select(_ chat: PanelChat) {
        switch chat.host {
        case .bottom: layout.activeBottomChat = chat.id; layout.bottomVisible = true
        case .tools: layout.activeToolsChat = chat.id; layout.rightVisible = true
        }
    }

    /// 面板里的会话移出:回到编辑区标签。
    /// - Parameter chat: 面板会话
    func undockChat(_ chat: PanelChat) {
        removeDocked(chat)
        let id = dock.open(.chat(projectID: chat.projectID, slot: chat.slot), title: sessions[chat.projectID]?.sessionTitle ?? chat.projectID, preview: false)
        dock.activate(id)
        syncSelectionFromDock()
    }

    /// 关闭面板里的会话(会话随之回收)。
    /// - Parameter chat: 面板会话
    func closeDocked(_ chat: PanelChat) {
        removeDocked(chat)
        reapConversations()
    }

    /// 某面板里的全部会话。
    /// - Parameter host: 面板
    func dockedChats(in host: PanelChatHost) -> [PanelChat] {
        layout.dockedChats.filter { $0.host == host }
    }

    /// 某面板当前选中的会话(没有或已失效为 nil)。
    /// - Parameter host: 面板
    func activeChat(in host: PanelChatHost) -> PanelChat? {
        let id = host == .bottom ? layout.activeBottomChat : layout.activeToolsChat
        return layout.dockedChats.first { $0.id == id }
    }

    private func removeDocked(_ chat: PanelChat) {
        layout.dockedChats.removeAll { $0 == chat }
        if layout.activeBottomChat == chat.id { layout.activeBottomChat = nil }
        if layout.activeToolsChat == chat.id { layout.activeToolsChat = nil }
    }
}
