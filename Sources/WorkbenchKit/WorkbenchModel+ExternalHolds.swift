// @author ixxxxoooo
// 会话的外部持有:IDE 窗口(非融合模式)的 Agent 面板使用专属槽位的会话,它没有 dock 标签。
// 登记持有关系后,`reapConversations` 不会误回收它;窗口关闭或换槽位时释放并回收,避免 Agent 进程泄漏。

import Foundation

extension WorkbenchModel {
    /// 登记某个持有者占用的会话。一个持有者同一时刻只占用一个会话,换槽位会释放(并回收)旧的。
    /// - Parameters:
    ///   - owner: 持有者标识(如 IDE 窗口 ID),不能为空
    ///   - project: 项目 ID
    ///   - slot: 会话槽位
    public func holdConversation(owner: String, project: String, slot: String?) {
        guard !owner.isEmpty else { return }
        let key = ConversationKey(projectID: project, slot: slot)
        let previous = externalHolds[owner]
        externalHolds[owner] = key
        if let previous, previous != key { reapConversations() }
    }

    /// 释放某个持有者占用的会话并回收(没有任何标签或其他持有者引用时才会真正结束进程)。
    /// - Parameter owner: 持有者标识
    public func releaseConversation(owner: String) {
        guard externalHolds.removeValue(forKey: owner) != nil else { return }
        reapConversations()
    }

    /// 当前外部持有登记数(测试与诊断用)。
    public var externalHoldCount: Int { externalHolds.count }
}
