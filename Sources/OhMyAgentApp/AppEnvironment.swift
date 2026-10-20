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
        defer { LaunchTrace.mark("工作台模型加载完成") }
        let store = DemoLaunch.environment.map { WorkbenchStore(fileURL: $0.workbenchStoreURL) } ?? WorkbenchStore()
        workbench = WorkbenchModel(store: store) { url in
            AppEnvironment.makeSession(workspace: url, descriptor: Toolchain.defaultDescriptor())
        }
        // 打开其他引擎的历史会话时,按 Agent ID 找到注册的描述符,用原引擎承载
        workbench.makeAgentSession = { url, agentID in
            guard let descriptor = AgentRegistryModel.shared.data.allAgents.first(where: { $0.id == agentID }) else { return nil }
            return AppEnvironment.makeSession(workspace: url, descriptor: descriptor)
        }
        workbench.defaultAgentID = { Toolchain.defaultDescriptor().id }
        // 待命会话被新对话/新标签认领后,立即补一个新的,下一次同样零等待
        workbench.onWarmSessionTaken = { [weak self] in self?.scheduleEngineWarmup(delay: .milliseconds(800)) }
        workbench.warmPool.factory = { url, descriptor in AppEnvironment.makeSession(workspace: url, descriptor: descriptor) }
        // 多文件夹工作区:文件索引覆盖附加文件夹
        let wb = workbench
        WorkspaceIndexModel.shared.extraRootsProvider = { id in wb.projects.first(where: { $0.id == id })?.extraFolders ?? [] }
        // Bridge 的 browser_*:在工作区的内置浏览器标签页上执行
        BrowserController.shared.ephemeral = ProcessInfo.processInfo.environment["OMA_DEMO"] != nil
        BrowserProvider.shared.install { workspace, command in
            await BrowserController.shared.run(command, workspace: workspace)
        }
        // 审批用:点击、输入等没有 url 参数的动作按浏览器当前页面判断(权限请求在主线程处理)
        BrowserProvider.shared.installCurrentURL { workspace in
            MainActor.assumeIsolated { BrowserController.shared.currentURL(workspace: workspace) }
        }
        // Bridge 的 search_code:走三元组索引,覆盖主目录与全部附加文件夹
        CodeSearchProvider.shared.install { workspace, query in
            let (extras, cached) = await MainActor.run { () -> ([String], [String]?) in
                let index = WorkspaceIndexModel.shared
                return (wb.projects.first(where: { $0.id == workspace })?.extraFolders ?? [], index.root == workspace && !index.files.isEmpty ? index.files : nil)
            }
            let options = SearchOptions(query: query.query, caseSensitive: query.caseSensitive, wholeWord: query.wholeWord, isRegex: query.isRegex, pathFilter: query.pathFilter)
            let output = await WorkspaceSearch.searchRoots([(root: workspace, files: cached)] + extras.map { (root: $0, files: nil) }, options: options)
            var matches: [CodeSearchMatch] = []
            for file in output.files {
                for hit in file.hits where matches.count < query.maxResults {
                    matches.append(CodeSearchMatch(root: file.root ?? workspace, path: file.path, line: hit.line, preview: hit.preview))
                }
            }
            return CodeSearchResult(matches: matches, totalHits: output.totalHits, fileCount: output.files.count, truncated: output.truncated,
                                    error: output.error, indexed: output.indexed, scannedFiles: output.scannedFiles)
        }
        // 切换项目后,为新项目重新安排预热
        workbench.onProjectSelected = { [weak self] _ in self?.scheduleEngineWarmup(delay: .seconds(2)) }
        workbench.onProjectRemoved = { root in TerminalStore.shared.remove(WorkbenchModel.residentTerminalID(root: root)) }
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
        // 默认引擎的待命会话排第一:下一个新对话/历史标签直接认领(即使默认引擎正是当前引擎)
        let defaultID = Toolchain.defaultDescriptor().id
        let ordered = (enabled.contains { $0.id == defaultID } ? [defaultID] : []) + plan.filter { $0 != defaultID }
        let descriptors = ordered.compactMap { wanted in enabled.first { $0.id == wanted } }
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
        // 性能观测:注册容量指标,并启动资源采样(采样前先在主线程刷新指标)
        PerfGauges.register(workbench: workbench)
        ResourceSampler.shared.start(intervalSeconds: ResourceSampler.configuredInterval()) { await PerfGauges.refresh() }
        // 会话驻留:闲置/超限的会话休眠 Agent 进程,系统内存紧张时收紧(演示与脚本化 Agent 的会话不是 claudeACP,不受影响)
        workbench.startResidencyMonitor()
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
