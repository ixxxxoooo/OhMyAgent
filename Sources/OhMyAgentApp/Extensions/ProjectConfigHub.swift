// @author ygw
// 项目配置枢纽:按工作区共享一个 `ConfigCenter`,供对话区读取本机的 MCP、Skills、命令与子 Agent。
// 设置页自己有独立的 ConfigCenter(随设置页生灭);这里的实例随应用存活,文件变化时自动刷新。

import ChatKit
import ClaudeConfigKit
import AgentHost
import Foundation
import OMLog

/// 按工作区缓存的配置中心。
@MainActor
@Observable
final class ProjectConfigHub {
    static let shared = ProjectConfigHub()

    @ObservationIgnored private var centers: [String: ConfigCenter] = [:]
    @ObservationIgnored private var runnerReady = false
    @ObservationIgnored private var runner: CLIRunner?
    @ObservationIgnored private let log = Log.app

    /// 取(必要时创建并启动)某个工作区的配置中心。主目录视为「无项目」。
    /// - Parameter workspace: 工作区目录
    /// - Returns: 配置中心
    func center(for workspace: URL) -> ConfigCenter {
        let key = workspace.standardizedFileURL.path
        if let existing = centers[key] { return existing }
        let isHome = key == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let center = ConfigCenter(paths: ClaudePaths(workspace: isHome ? nil : workspace))
        center.setRunner(runner)
        center.start()
        centers[key] = center
        if !runnerReady { resolveRunner() }
        return center
    }

    /// 定位 `claude` 后给所有中心设置 CLI 执行器(`mcp list` 等健康检查需要)。
    private func resolveRunner() {
        runnerReady = true
        Task { [weak self] in
            let tools = await Toolchain.shared.resolve()
            guard let self, let claude = tools.claudePath else {
                self?.log.warning("未找到 claude,MCP 健康检查不可用")
                return
            }
            let runner = CLIRunner(executable: claude, environment: tools.environment)
            self.runner = runner
            for center in self.centers.values { center.setRunner(runner) }
        }
    }

    // MARK: - 对话区所需的目录

    /// 斜杠补全用的 Skills/自定义命令条目。
    /// - Parameter workspace: 工作区
    func slashEntries(for workspace: URL) -> [SlashEntry] {
        center(for: workspace).snapshot.skills
            .filter { $0.userInvocable && $0.overriddenBy == nil }
            .map { item in
                let isSkill = item.kind == .skill
                var badge: String
                switch item.source {
                case .plugin(let name): badge = String(localized: "插件") + " " + name
                case .scope(let scope): badge = isSkill ? "Skill" : scope.displayName
                }
                if case .plugin = item.source, isSkill { badge = "Skill · " + badge }
                return SlashEntry(name: item.name, summary: item.description, badge: badge, kind: isSkill ? .skill : .customCommand)
            }
    }

    /// `@agent-名称` 提及候选。
    /// - Parameter workspace: 工作区
    func agentMentions(for workspace: URL) -> [(name: String, summary: String, badge: String)] {
        center(for: workspace).snapshot.agents
            .filter { $0.overriddenBy == nil }
            .map { ($0.name, $0.description, $0.source.displayName) }
    }
}
