// @author ixxxxoooo
// 应用级环境:唯一的工作台模型与会话工厂。启动时按环境变量/旧版偏好恢复项目。

import AgentHost
import ChatKit
import Foundation
import OMLog
import WorkbenchKit

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let workbench: WorkbenchModel

    private init() {
        let store = DemoLaunch.environment.map { WorkbenchStore(fileURL: $0.workbenchStoreURL) } ?? WorkbenchStore()
        workbench = WorkbenchModel(store: store) { url in
            AppEnvironment.makeSession(workspace: url, descriptor: Toolchain.defaultDescriptor())
        }
        // 打开其他引擎的历史会话时,按 Agent ID 找到注册的描述符,用原引擎承载
        workbench.makeAgentSession = { url, agentID in
            guard let descriptor = AgentRegistryModel.shared.data.allAgents.first(where: { $0.id == agentID }) else { return nil }
            return AppEnvironment.makeSession(workspace: url, descriptor: descriptor)
        }
        workbench.warmPool.factory = { url, descriptor in AppEnvironment.makeSession(workspace: url, descriptor: descriptor) }
        // 切换项目后,为新项目重新安排预热
        workbench.onProjectSelected = { [weak self] _ in self?.scheduleEngineWarmup(delay: .seconds(2)) }
    }

    /// 为当前项目安排引擎预热(演示/脚本化 Agent 模式不预热)。
    /// - Parameter delay: 开始前的等待
    func scheduleEngineWarmup(delay: Duration) {
        guard !DemoLaunch.isActive, ProcessInfo.processInfo.environment["OMA_AGENT"] == nil else { return }
        let mode = WarmMode.current()
        guard mode != .off, let id = workbench.selectedProjectID,
              let project = workbench.projects.first(where: { $0.id == id }),
              let current = workbench.activeSession else { return }
        let enabled = AgentRegistryModel.shared.data.enabledAgents
        let recent = project.sessions.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }.compactMap(\.agentId)
        let plan = EngineWarmPlanner.plan(mode: mode, currentEngineID: current.descriptor.id, recentEngineIDs: recent, enabledEngineIDs: enabled.map(\.id))
        let descriptors = plan.compactMap { wanted in enabled.first { $0.id == wanted } }
        workbench.warmPool.warmSequentially(descriptors, workspace: current.workspace, delay: delay)
    }

    /// 打开引擎选择器时预热其余引擎(受上限约束,逐个进行)。
    /// - Parameter current: 当前会话
    func warmOtherEngines(current: SessionModel) {
        guard !DemoLaunch.isActive, ProcessInfo.processInfo.environment["OMA_AGENT"] == nil else { return }
        let enabled = AgentRegistryModel.shared.data.enabledAgents
        let ids = EngineWarmPlanner.planForPicker(mode: WarmMode.current(), currentEngineID: current.descriptor.id, enabledEngineIDs: enabled.map(\.id))
        let descriptors = ids.compactMap { wanted in enabled.first { $0.id == wanted } }
        workbench.warmPool.warmSequentially(descriptors, workspace: current.workspace, delay: .milliseconds(100))
    }

    /// 创建会话模型并接入应用层能力(系统通知)。
    static func makeSession(workspace: URL, descriptor: AgentDescriptor) -> SessionModel {
        let model = SessionModel(workspace: workspace, descriptor: descriptor)
        // 演示模式不发系统通知
        if !DemoLaunch.isActive { model.notifier = { title, message in AppNotifier.send(title: title, message: message) } }
        return model
    }

    /// 启动时恢复项目:`OMA_OPEN_PROJECTS`(冒号分隔,调试用)优先;
    /// 工作台为空且存在旧版「最近工作区」偏好时迁移该目录(主目录除外)。
    func bootstrap() {
        let env = ProcessInfo.processInfo.environment
        if let list = env["OMA_OPEN_PROJECTS"], !list.isEmpty {
            for path in list.split(separator: ":") { workbench.openProject(URL(fileURLWithPath: String(path))) }
        } else if DemoLaunch.isActive {
            // 演示模式:工作台为空(首次或重置)时打开全部演示项目,首个项目为当前项目
            if workbench.projects.isEmpty {
                let ids = DemoLaunch.projects.compactMap { workbench.openProject(URL(fileURLWithPath: $0.path)) }
                if let first = ids.first { workbench.select(project: first) }
            }
        } else if workbench.projects.isEmpty,
                  let legacy = UserDefaults.standard.string(forKey: "lastWorkspacePath"),
                  legacy != NSHomeDirectory() {
            workbench.openProject(URL(fileURLWithPath: legacy))
            Log.app.info("已迁移旧版最近工作区", ["path": legacy])
        }
        if let selected = workbench.selectedProjectID { workbench.select(project: selected) }
        scheduleEngineWarmup(delay: .seconds(3))
    }

    /// 当前所有会话(当前项目的排在最前)。
    var sessionModels: [SessionModel] {
        let active = workbench.activeSession
        return (active.map { [$0] } ?? []) + workbench.allSessions.filter { $0 !== active }
    }
}
