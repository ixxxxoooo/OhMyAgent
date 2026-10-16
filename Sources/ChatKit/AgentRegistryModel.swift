// @author ixxxxoooo
// 可观察的 Agent 注册表模型:设置页与窗口工具栏共享,修改即写回 agents.json。

import AgentHost
import Foundation
import Observation

/// 注册表模型(主线程)。
@MainActor
@Observable
public final class AgentRegistryModel {
    public static let shared = AgentRegistryModel()

    public private(set) var data: AgentRegistryData
    public private(set) var lastError: String?
    @ObservationIgnored private let store: AgentRegistryStore

    /// - Parameter store: 存储位置(测试可传临时路径)
    public init(store: AgentRegistryStore = AgentRegistryStore()) {
        self.store = store
        self.data = store.load()
    }

    /// 文件路径。
    public var fileURL: URL { store.url }

    /// 重新读取文件(外部手工编辑后调用)。
    public func reload() { data = store.load() }

    /// 修改并保存。
    /// - Parameter change: 修改闭包
    public func update(_ change: (inout AgentRegistryData) -> Void) {
        var next = data
        change(&next)
        do {
            try store.save(next)
            lastError = nil
        } catch {
            lastError = String(localized: "保存 agents.json 失败:\(error.localizedDescription)")
        }
        data = next
    }

    /// 新增或替换自定义 Agent(按 id)。内置 id 会被拒绝。
    /// - Returns: 失败原因;成功返回 nil
    @discardableResult
    public func upsert(_ agent: AgentDescriptor) -> String? {
        if agent.id.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Agent 标识不能为空") }
        if AgentDescriptor.builtIns.contains(where: { $0.id == agent.id }) { return String(localized: "标识 \(agent.id) 已被内置 Agent 占用") }
        // 一键安装的 Agent(registryId)由安装器解析可执行文件,不要求填写命令
        if agent.registryId == nil, (agent.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "请填写可执行文件或命令名") }
        update { value in
            if let index = value.agents.firstIndex(where: { $0.id == agent.id }) { value.agents[index] = agent } else { value.agents.append(agent) }
        }
        return nil
    }

    /// 删除自定义 Agent;若它是默认 Agent 则清除默认。
    public func remove(agentId: String) {
        update { value in
            value.agents.removeAll { $0.id == agentId }
            if value.defaultAgent == agentId { value.defaultAgent = nil }
        }
    }

    /// 启用 / 停用 Agent(内置 Agent 的启用状态不可改)。
    public func setEnabled(_ enabled: Bool, agentId: String) {
        update { value in
            if let index = value.agents.firstIndex(where: { $0.id == agentId }) { value.agents[index].enabled = enabled }
            if !enabled, value.defaultAgent == agentId { value.defaultAgent = nil }
        }
    }

    /// 设置默认 Agent。
    public func setDefault(agentId: String?) { update { $0.defaultAgent = agentId } }

    /// 新增或替换 Agent-as-MCP 登记项。
    public func upsertMCP(_ entry: AgentMCPEntry) {
        update { value in
            if let index = value.mcpAgents.firstIndex(where: { $0.id == entry.id }) { value.mcpAgents[index] = entry } else { value.mcpAgents.append(entry) }
        }
    }

    /// 删除 Agent-as-MCP 登记项。
    public func removeMCP(id: String) { update { $0.mcpAgents.removeAll { $0.id == id } } }
}
