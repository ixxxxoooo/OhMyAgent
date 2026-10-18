// @author ixxxxoooo
// Agent 终端仓库:记录「在终端面板里打开查看」的 Agent 终端(只读镜像)。
// 只在内存里保存:Agent 终端的会话随应用退出而消失,不进入持久化的 `TerminalPanelState`。

import ChatKit
import Foundation
import Observation

/// 终端面板里的一个 Agent 终端条目。
struct AgentTerminalEntry: Identifiable {
    /// 终端标识(等于 Bash 工具调用的 toolCallId 或内置终端 id)
    var id: String { session.id }
    let session: TerminalSession
}

@MainActor
@Observable
final class AgentTerminalStore {
    static let shared = AgentTerminalStore()

    /// 项目根 → 已打开的 Agent 终端(按打开顺序)
    private(set) var entries: [String: [AgentTerminalEntry]] = [:]
    /// 项目根 → 当前激活的 Agent 终端 id;没有表示激活的是用户自己的终端
    private(set) var activeIDs: [String: String] = [:]

    init() {}

    /// 某项目的 Agent 终端。
    func entries(for root: String) -> [AgentTerminalEntry] { entries[root] ?? [] }

    /// 某项目当前激活的 Agent 终端 id(nil 表示激活的是用户终端)。
    func activeID(for root: String) -> String? { activeIDs[root] }

    /// 打开(已存在则只激活)一个 Agent 终端。
    /// - Parameters:
    ///   - session: 终端会话
    ///   - root: 项目根目录
    func open(_ session: TerminalSession, root: String) {
        if entries[root]?.contains(where: { $0.id == session.id }) != true {
            entries[root, default: []].append(AgentTerminalEntry(session: session))
        }
        activeIDs[root] = session.id
    }

    /// 激活某个 Agent 终端;传 nil 回到用户终端。
    func activate(_ id: String?, root: String) {
        if let id, entries[root]?.contains(where: { $0.id == id }) != true { return }
        activeIDs[root] = id
    }

    /// 关闭条目(只移除镜像,不影响 Agent 的命令);关闭的是激活项时回到用户终端。
    func close(_ id: String, root: String) {
        entries[root]?.removeAll { $0.id == id }
        if entries[root]?.isEmpty == true { entries[root] = nil }
        if activeIDs[root] == id { activeIDs[root] = nil }
    }
}
