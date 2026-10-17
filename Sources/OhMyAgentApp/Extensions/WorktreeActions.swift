// @author ixxxxoooo
// 工作树相关的客户端命令:`/worktree`、`/apply-worktree`、`/delete-worktree`、`/best-of-n`,以及数量超限时的清理确认。
// 工作树在工作台里是带 `WorktreeLink` 的项目;创建/合并/删除走 `WorktreeManager`(GitKit),这里只负责串起界面。

import CanvasKit
import ChatKit
import Foundation
import GitKit
import OMLog
import WorkbenchKit

/// 工作树命令的界面编排。
@MainActor
enum WorktreeActions {
    private static let log = Log.git
    /// 输出面板里「Worktrees Setup」通道的日志标记
    nonisolated static let setupChannel = "Worktrees Setup"
    /// 上次自动清理检查的时间戳键
    private static let lastCleanupKey = "worktree.lastCleanupCheck"

    /// 路由工作树类命令。
    /// - Parameters:
    ///   - command: 命令
    ///   - model: 发出命令的会话
    static func handle(_ command: LocalCommand, in model: SessionModel) {
        switch command {
        case .worktree(let title): Task { await create(title: title, from: model) }
        case .applyWorktree: Task { await apply(from: model) }
        case .deleteWorktree: Task { await delete(from: model) }
        case .bestOfN(let models, let task): Task { await bestOfN(models: models, task: task, from: model) }
        default: break
        }
    }

    // MARK: 创建

    /// 创建一个工作树项目并在其中开始新对话。
    /// - Parameters:
    ///   - title: 标题(空则用「task」)
    ///   - model: 发起会话
    /// - Returns: 新工作树项目 ID 与路径
    @discardableResult
    static func create(title: String, from model: SessionModel, quiet: Bool = false) async -> (projectID: String, link: WorktreeLink, path: String)? {
        let workbench = AppEnvironment.shared.workbench
        guard let project = workbench.projects.first(where: { $0.id == model.workspace.path }) else { return nil }
        // 在工作树里再开工作树时,仍以原项目为主检出
        let origin = workbench.worktreeOrigin(of: project.id) ?? project
        guard origin.extraFolders.isEmpty else {
            model.timeline.appendNotice(WorktreeError.multiRoot.localizedDescription, severity: "warning")
            return nil
        }
        guard let repo = await GitRepository.discover(from: origin.id), repo.root.path == GitRepository.realPath(origin.id) || repo.root.path == origin.id else {
            model.timeline.appendNotice(WorktreeError.notARepository.localizedDescription, severity: "warning")
            return nil
        }
        do {
            let created = try await WorktreeManager.create(in: repo, title: title.isEmpty ? "task" : title) { line in
                Log.git.info("Worktrees Setup", ["channel": WorktreeActions.setupChannel, "line": String(line.prefix(300))])
            }
            let link = WorktreeLink(origin: origin.id, branch: created.branch, base: created.base)
            let name = origin.name + " · " + (created.branch as NSString).lastPathComponent
            guard let id = workbench.openWorktreeProject(path: created.path, link: link, name: name) else { return nil }
            if !quiet {
                workbench.newConversation(in: id)
                model.timeline.appendNotice(String(localized: "已创建工作树 `\(created.branch)`,在新对话里继续。"), detail: created.path)
            }
            log.info("创建工作树", ["branch": created.branch, "path": created.path])
            await offerCleanup(in: repo, origin: origin.id, model: model)
            return (id, link, created.path)
        } catch {
            log.error("创建工作树失败", error: error, ["origin": origin.id])
            model.timeline.appendNotice(String(localized: "创建工作树失败:\(error.localizedDescription)"), isError: true)
            return nil
        }
    }

    /// 「在工作树中运行」:建工作树、在其中新对话并发送首条消息。
    /// - Parameters:
    ///   - text: 用户消息
    ///   - images: 图片附件
    ///   - model: 原会话(失败时把消息放回草稿)
    static func sendInWorktree(_ text: String, images: [ImageAttachment], from model: SessionModel) async {
        guard let made = await create(title: String(text.prefix(40)), from: model),
              let session = AppEnvironment.shared.workbench.sessions[made.projectID] else {
            model.draft = text
            model.attachments = images
            return
        }
        session.send(text, images: images)
    }

    // MARK: 应用与删除

    /// 当前会话所在的工作树项目及其原项目。
    private static func context(of model: SessionModel) -> (entry: ProjectEntry, link: WorktreeLink, origin: ProjectEntry)? {
        let workbench = AppEnvironment.shared.workbench
        guard let entry = workbench.projects.first(where: { $0.id == model.workspace.path }), let link = entry.worktree,
              let origin = workbench.projects.first(where: { $0.id == link.origin }) else {
            model.timeline.appendNotice(String(localized: "当前项目不是工作树;先用 `/worktree` 创建一个。"), severity: "warning")
            return nil
        }
        return (entry, link, origin)
    }

    /// 把当前工作树的改动提交并合并回原项目。
    static func apply(from model: SessionModel) async {
        guard let (entry, link, origin) = context(of: model) else { return }
        let repo = GitRepository(root: origin.url)
        do {
            try await WorktreeManager.apply(origin: repo, worktreePath: entry.id, branch: link.branch)
            model.timeline.appendNotice(String(localized: "已把 `\(link.branch)` 合并回「\(origin.name)」。可用 `/delete-worktree` 清理这个工作树。"))
            log.info("应用工作树", ["branch": link.branch])
        } catch {
            log.error("应用工作树失败", error: error, ["branch": link.branch])
            let conflict = (error as? WorktreeError) == nil
            model.timeline.appendNotice(String(localized: "应用工作树失败:\(error.localizedDescription)"),
                                        isError: true, detail: conflict ? String(localized: "若存在合并冲突,请在原项目的 Git 面板里解决后提交。") : nil)
        }
    }

    /// 确认后删除当前工作树(含分支)与对应项目。
    static func delete(from model: SessionModel) async {
        guard let (entry, link, origin) = context(of: model) else { return }
        guard OMDialog.confirm(title: String(localized: "删除工作树?"), message: String(localized: "将删除目录与分支 \(link.branch),未合并的改动会丢失。"), confirmTitle: String(localized: "删除"), destructive: true) else { return }
        let workbench = AppEnvironment.shared.workbench
        do {
            try await WorktreeManager.remove(origin: GitRepository(root: origin.url), worktreePath: entry.id, branch: link.branch, deleteBranch: true)
            workbench.removeProject(entry.id)
            workbench.select(project: origin.id)
            log.info("删除工作树", ["branch": link.branch])
        } catch {
            log.error("删除工作树失败", error: error, ["branch": link.branch])
            model.timeline.appendNotice(String(localized: "删除工作树失败:\(error.localizedDescription)"), isError: true)
        }
    }

    // MARK: 清理策略

    /// 工作树数量超过上限时,列出最旧的干净工作树请用户确认清理(从不静默删除)。
    private static func offerCleanup(in repo: GitRepository, origin: String, model: SessionModel) async {
        let items = await WorktreeManager.listManaged(in: repo)
        let doomed = WorktreeManager.cleanupCandidates(items, maxCount: ClientPrefs.worktreeMaxCount())
        guard !doomed.isEmpty else { return }
        let names = doomed.prefix(8).map { "• " + $0.branch }.joined(separator: "\n")
        guard OMDialog.confirm(title: String(localized: "清理旧工作树?"),
                               message: String(localized: "工作树数量超过上限 \(ClientPrefs.worktreeMaxCount()),将删除最旧且没有未提交改动的 \(doomed.count) 个:\n\(names)"),
                               confirmTitle: String(localized: "清理"), destructive: true) else { return }
        let workbench = AppEnvironment.shared.workbench
        let removed = await WorktreeManager.cleanup(in: repo, maxCount: ClientPrefs.worktreeMaxCount())
        for item in removed { workbench.removeProject(item.path) }
        model.timeline.appendNotice(String(localized: "已清理 \(removed.count) 个旧工作树。"))
    }

    /// 启动后按间隔检查一次当前项目的工作树数量(间隔由设置控制)。
    static func periodicCleanup() {
        let defaults = UserDefaults.standard
        let interval = TimeInterval(ClientPrefs.worktreeCleanupHours()) * 3600
        let last = defaults.object(forKey: lastCleanupKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return }
        defaults.set(Date(), forKey: lastCleanupKey)
        let workbench = AppEnvironment.shared.workbench
        guard let project = workbench.selectedProject, project.worktree == nil, let model = workbench.sessions[project.id] else { return }
        Task {
            guard let repo = await GitRepository.discover(from: project.id) else { return }
            await offerCleanup(in: repo, origin: project.id, model: model)
        }
    }

    // MARK: best-of-n

    /// 同一任务交给多个模型,各在独立工作树里并行完成,并生成对比画布。
    static func bestOfN(models: [String], task: String, from model: SessionModel) async {
        guard !models.isEmpty, !task.isEmpty else {
            model.timeline.appendNotice(String(localized: "用法:`/best-of-n 模型1,模型2 任务`"), severity: "warning")
            return
        }
        var runs: [BestOfRun] = []
        for name in models.prefix(LocalCommands.bestOfNLimit) {
            guard let made = await create(title: task + "-" + name, from: model, quiet: true) else { continue }
            let workbench = AppEnvironment.shared.workbench
            workbench.newConversation(in: made.projectID)
            guard let session = workbench.sessions[made.projectID] else { continue }
            session.pendingModelName = name
            session.send(task, bypassLocal: true)
            runs.append(BestOfRun(model: name, projectID: made.projectID, path: made.path, branch: made.link.branch, base: made.link.base, session: session))
        }
        guard !runs.isEmpty else { return }
        let workbench = AppEnvironment.shared.workbench
        let origin = workbench.worktreeOrigin(of: runs[0].projectID)?.id ?? model.workspace.path
        do {
            let store = model.canvasStore
            let document = try store.create(title: String(localized: "多模型对比") + " · " + String(task.prefix(24)), blocks: comparisonBlocks(task: task, runs: runs, stats: [:], done: false), projectPath: origin)
            workbench.openCanvas(id: document.id, title: document.title)
            model.timeline.appendNotice(String(localized: "已为 \(runs.count) 个模型创建工作树并开始执行,对比画布会在全部完成后更新。"))
            Task { await watch(runs: runs, task: task, canvasID: document.id, store: store) }
        } catch {
            log.error("创建对比画布失败", error: error)
        }
    }

    /// 一个 best-of-n 运行。
    struct BestOfRun {
        var model: String
        var projectID: String
        var path: String
        var branch: String
        var base: String
        var session: SessionModel
    }

    /// 轮询各会话,全部完成后统计改动并更新画布(最长 2 小时)。
    private static func watch(runs: [BestOfRun], task: String, canvasID: String, store: CanvasStore) async {
        var started = Set<String>()
        for _ in 0..<2400 {
            try? await Task.sleep(for: .seconds(3))
            for run in runs where run.session.isRunning { started.insert(run.projectID) }
            let finished = runs.allSatisfy { started.contains($0.projectID) && !$0.session.isRunning }
            guard finished else { continue }
            var stats: [String: GitShortStat] = [:]
            for run in runs {
                if let stat = try? await GitRepository(root: URL(fileURLWithPath: run.path)).workingTreeStat(from: run.base) { stats[run.projectID] = stat }
            }
            _ = try? store.update(id: canvasID, title: nil, blocks: comparisonBlocks(task: task, runs: runs, stats: stats, done: true), appendBlocks: nil)
            return
        }
    }

    /// 对比画布的内容。
    static func comparisonBlocks(task: String, runs: [BestOfRun], stats: [String: GitShortStat], done: Bool) -> [CanvasBlock] {
        let rows = runs.map { run -> [String] in
            let stat = stats[run.projectID]
            let change = stat.map { String(localized: "\($0.files) 个文件 +\($0.insertions) −\($0.deletions)") } ?? "—"
            let state = done ? String(localized: "已完成") : String(localized: "运行中")
            return [run.model, run.branch, change, state]
        }
        return [
            .callout(tone: done ? .success : .info, title: done ? String(localized: "全部完成") : String(localized: "正在执行"), text: task),
            .table(CanvasTable(columns: [String(localized: "模型"), String(localized: "分支"), String(localized: "改动"), String(localized: "状态")], rows: rows, title: nil)),
            .markdown(String(localized: "在各工作树项目里查看改动;满意的那个用 `/apply-worktree` 合并回原项目,其余用 `/delete-worktree` 清理。")),
        ]
    }
}
