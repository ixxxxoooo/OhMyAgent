// @author ixxxxoooo
// 源代码管理面板的宿主抽象:Agent 窗口右栏与 IDE 侧栏共用同一套 `SCMContent`,
// 只有「怎么打开差异/文件/历史」与「AI 提交说明用哪个网关」由各自的宿主提供。

import ChatKit
import Foundation
import WorkbenchKit

/// 源代码管理面板的宿主:把打开标签等动作落到各自的窗口模型。
@MainActor
protocol SCMHost {
    /// 在编辑器中打开文件。
    /// - Parameters:
    ///   - path: 文件绝对路径
    ///   - preview: 是否预览方式
    func openFile(_ path: String, preview: Bool)
    /// 打开某文件的差异标签。
    /// - Parameter path: 文件绝对路径
    func openDiff(_ path: String)
    /// 打开 Git 提交历史标签。
    /// - Parameters:
    ///   - project: 仓库根目录
    ///   - path: 仅看该文件的历史;nil 为整个仓库
    func openHistory(project: String, path: String?)
    /// 打开文件的逐行追溯标签。
    /// - Parameter path: 文件绝对路径
    func openBlame(_ path: String)
    /// 打开某个提交里单个文件的差异标签。
    /// - Parameters:
    ///   - root: 仓库根目录
    ///   - commit: 提交哈希
    ///   - path: 仓库内相对路径
    func openCommitDiff(root: String, commit: String, path: String)
    /// 生成提交说明用的轻量模型网关;没有可用会话时为 nil。
    var utilityGateway: (url: URL, alias: String)? { get }
}

/// Agent 窗口(工作台)宿主。
@MainActor
struct WorkbenchSCMHost: SCMHost {
    let workbench: WorkbenchModel

    func openFile(_ path: String, preview: Bool) { workbench.openFile(path, preview: preview) }
    func openDiff(_ path: String) { workbench.openDiff(path) }
    func openHistory(project: String, path: String?) { workbench.openHistory(project: project, path: path) }
    func openBlame(_ path: String) { workbench.openBlame(path) }
    func openCommitDiff(root: String, commit: String, path: String) { workbench.openCommitDiff(root: root, commit: commit, path: path) }
    var utilityGateway: (url: URL, alias: String)? { workbench.activeSession?.utilityGateway }
}

/// IDE 窗口宿主。
@MainActor
struct IDESCMHost: SCMHost {
    let workspace: IDEWorkspace

    func openFile(_ path: String, preview: Bool) { workspace.open(path, preview: preview) }
    func openDiff(_ path: String) { workspace.model.openDiff(path) }
    func openHistory(project: String, path: String?) { workspace.model.openHistory(project: project, path: path) }
    func openBlame(_ path: String) { workspace.model.openBlame(path) }
    func openCommitDiff(root: String, commit: String, path: String) { workspace.model.openCommitDiff(root: root, commit: commit, path: path) }
    var utilityGateway: (url: URL, alias: String)? { workspace.agentSession?.utilityGateway }
}
