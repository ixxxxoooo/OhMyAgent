// @author ixxxxoooo
// 融合模式所需的会话查询:IDE 窗口的 Agent 面板与 Agent 窗口共用同一份会话标签,
// 面板里的「标签条」直接读取工作台中栏里属于某项目的会话标签,点击/关闭走工作台同一入口。

import Foundation

extension WorkbenchModel {
    /// 某项目在中栏(含全部分屏组)里打开的会话标签,按标签顺序返回。
    /// - Parameter projectID: 项目 ID
    /// - Returns: 会话标签列表;项目没有会话标签时为空
    public func chatTabs(in projectID: String) -> [WorkbenchTab] {
        dock.allTabs.filter {
            if case .chat(let id, _) = $0.kind { return id == projectID }
            return false
        }
    }

    /// 某项目「当前会话」对应的标签 ID(最近激活的会话标签;没有记录时取第一个会话标签)。
    /// - Parameter projectID: 项目 ID
    /// - Returns: 标签 ID;项目没有会话标签时为 nil
    public func activeChatTabID(in projectID: String) -> UUID? {
        if let slot = lastSlot[projectID], let tab = dock.tab(for: .chat(projectID: projectID, slot: slot)) { return tab.id }
        return chatTabs(in: projectID).first?.id
    }
}
