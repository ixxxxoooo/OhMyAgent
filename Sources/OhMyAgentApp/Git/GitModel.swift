// @author ixxxxoooo
// Git 视图模型:每个项目一个,持有最近一次状态快照并串行化写操作(暂存/提交/推拉/分支…)。
// 所有 git 调用都在 GitKit 的后台子进程里执行,主线程只更新状态。

import AppKit
import Foundation
import GitKit
import Observation
import OMLog

/// 项目对应的仓库状态。
@MainActor
@Observable
final class GitModel {
    /// 仓库发现阶段
    enum Phase: Equatable {
        case unknown, notRepository, ready
    }

    let projectPath: String
    private(set) var phase: Phase = .unknown
    private(set) var repo: GitRepository?
    private(set) var status = GitStatus()
    private(set) var stats = GitLineStats()
    private(set) var branches: [GitBranch] = []
    private(set) var stashes: [GitStash] = []
    /// 正在执行的操作名(界面显示进度,并禁用重复触发)
    private(set) var busy: String?
    /// 最近一次失败的提示(用户关闭后清除)
    var lastError: String?
    var commitMessage = ""
    /// 修补上一次提交(amend)
    var amend = false
    @ObservationIgnored private var refreshing = false

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    /// 仓库根目录;未就绪为 nil。
    var rootPath: String? { repo?.root.path }

    /// 把仓库相对路径转为绝对路径。仓库根就是项目目录时沿用项目路径写法,
    /// 这样与资源管理器打开的是同一个标签(避免 `/tmp` 与 `/private/tmp` 两种写法重复开标签)。
    func absolutePath(_ relative: String) -> String {
        guard let repo else { return projectPath + "/" + relative }
        let base = GitRepository.realPath(projectPath) == GitRepository.realPath(repo.root.path) ? projectPath : repo.root.path
        return base + "/" + relative
    }

    /// 把绝对路径转为仓库相对路径;不在仓库内返回 nil。
    func relativePath(_ absolute: String) -> String? {
        repo?.relativePath(of: absolute)
    }

    /// 可提交的改动(不含冲突)。
    var committableCount: Int { status.changes.filter { !$0.isConflicted }.count }

    // MARK: 刷新

    /// 刷新状态、行数统计、分支与 stash;重复调用在上一次未完成时直接返回。
    /// - Parameter full: 为 true 时同时刷新分支与 stash 列表
    func refresh(full: Bool = true) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if repo == nil {
            repo = await GitRepository.discover(from: projectPath)
            phase = repo == nil ? .notRepository : .ready
            if let repo { Log.git.info("发现 Git 仓库", ["root": repo.root.lastPathComponent]) }
        }
        guard let repo else { return }
        do {
            let newStatus = try await repo.status()
            let newStats = try await repo.uncommittedStats(untracked: newStatus.untrackedChanges)
            if newStatus != status { status = newStatus }
            if newStats != stats { stats = newStats }
            if full {
                branches = try await repo.branches()
                stashes = try await repo.stashes()
            }
        } catch {
            Log.git.warning("刷新 Git 状态失败", ["error": "\(error)"])
            if (error as? GitError).map({ if case .notARepository = $0 { return true } else { return false } }) == true {
                self.repo = nil
                phase = .notRepository
            }
        }
    }

    // MARK: 写操作

    /// 串行执行一个写操作:设置忙状态、捕获错误、完成后刷新。
    /// - Parameters:
    ///   - title: 操作名(用于忙状态与日志)
    ///   - operation: 具体操作
    /// - Returns: 是否成功
    @discardableResult
    func perform(_ title: String, _ operation: @Sendable (GitRepository) async throws -> Void) async -> Bool {
        guard busy == nil, let repo else { return false }
        busy = title
        lastError = nil
        let started = ContinuousClock.now
        var success = true
        do {
            try await operation(repo)
        } catch {
            success = false
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.git.error("Git 操作失败", ["op": title, "error": String((lastError ?? "").prefix(300))])
        }
        busy = nil
        Log.git.info("Git 操作完成", ["op": title, "ok": "\(success)", "ms": "\((ContinuousClock.now - started).components.seconds * 1000)"])
        await refresh(full: true)
        return success
    }

    func stage(_ paths: [String]) async { await perform(String(localized: "暂存")) { try await $0.stage(paths) } }
    func stageAll() async { await perform(String(localized: "暂存全部")) { try await $0.stageAll() } }
    func unstage(_ paths: [String]) async { await perform(String(localized: "取消暂存")) { try await $0.unstage(paths) } }
    func unstageAll() async { await perform(String(localized: "取消全部暂存")) { try await $0.unstageAll() } }

    /// 丢弃修改(调用方应先确认)。
    func discard(_ paths: [String], untracked: [String] = []) async {
        await perform(String(localized: "丢弃修改")) { try await $0.discard(paths, untracked: untracked) }
    }

    /// 提交。没有暂存内容时先暂存全部(与 VS Code 的智能提交一致)。
    /// - Parameter push: 提交后是否继续推送
    func commit(push: Bool = false) async {
        let message = commitMessage
        let amending = amend
        // amend 时允许暂存区为空(只改提交说明);否则没有暂存内容就先暂存全部
        let needsStageAll = status.stagedChanges.isEmpty && !amending
        let ok = await perform(push ? String(localized: "提交并推送") : (amending ? String(localized: "修补上次提交") : String(localized: "提交"))) { repo in
            if needsStageAll { try await repo.stageAll() }
            try await repo.commit(message: message, amend: amending)
            if push { try await repo.push(status: nil) }
        }
        if ok { commitMessage = ""; amend = false }
    }

    /// 切换「修补上次提交」;打开且输入框为空时预填上一次提交的说明。
    func setAmend(_ on: Bool) async {
        amend = on
        guard on, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let repo,
              let last = try? await repo.log(limit: 1).first else { return }
        commitMessage = last.subject
    }

    /// 中止进行中的合并(调用方应先确认)。
    func abortMerge() async { await perform(String(localized: "中止合并")) { try await $0.abortMerge() } }

    func fetch() async { await perform(String(localized: "获取")) { try await $0.fetch() } }
    func pull(rebase: Bool = false) async { await perform(rebase ? String(localized: "拉取(rebase)") : String(localized: "拉取")) { try await $0.pull(rebase: rebase) } }
    func push() async { let current = status; await perform(String(localized: "推送")) { try await $0.push(status: current) } }

    func checkout(_ branch: String) async { await perform(String(localized: "切换分支")) { try await $0.checkout(branch) } }
    func createBranch(_ name: String) async { await perform(String(localized: "新建分支")) { try await $0.createBranch(name, checkout: true) } }
    func deleteBranch(_ name: String) async { await perform(String(localized: "删除分支")) { try await $0.deleteBranch(name, force: false) } }

    func stashPush(message: String?) async { await perform(String(localized: "暂存到 stash")) { try await $0.stashPush(message: message) } }
    func stashPop(_ index: Int) async { await perform(String(localized: "应用 stash")) { try await $0.stashPop(index: index) } }
    func stashDrop(_ index: Int) async { await perform(String(localized: "丢弃 stash")) { try await $0.stashDrop(index: index) } }

    func resolve(_ path: String, with resolution: GitConflictResolution) async {
        await perform(String(localized: "解决冲突")) { try await $0.resolve(path, with: resolution) }
    }

    func markResolved(_ path: String) async { await perform(String(localized: "标记已解决")) { try await $0.markResolved(path) } }

    /// 在项目目录初始化仓库。
    func initializeRepository() async {
        guard busy == nil else { return }
        busy = String(localized: "初始化")
        defer { busy = nil }
        do {
            repo = try await GitRepository.initialize(at: projectPath)
            phase = .ready
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.git.error("初始化仓库失败", ["error": "\(error)"])
        }
        await refresh(full: true)
    }
}

/// 全部项目的 Git 模型仓库。
@MainActor
final class GitStore {
    static let shared = GitStore()
    private var models: [String: GitModel] = [:]
    private init() {}

    /// 获取(必要时创建)项目的 Git 模型。
    func model(for projectPath: String) -> GitModel {
        if let existing = models[projectPath] { return existing }
        let model = GitModel(projectPath: projectPath)
        models[projectPath] = model
        return model
    }
}
