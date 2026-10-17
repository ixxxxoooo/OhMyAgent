// @author ixxxxoooo
// Git 工作树(`git worktree`):列表解析、新增、删除、合并回主检出与改动统计。
// 工作树让每个任务在隔离的检出里运行,互不干扰;路径与分支名都做合法性校验。

import Foundation
import OMLog

/// 一个工作树。
public struct GitWorktree: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// 检出目录(绝对路径)
    public var path: String
    /// 当前提交
    public var head: String
    /// 分支名(游离 HEAD 时为 nil)
    public var branch: String?
    public var isBare = false
    public var isLocked = false
    /// 目录已丢失,可被 `git worktree prune` 清理
    public var isPrunable = false
    /// 是否主检出(`git worktree list` 的第一项)
    public var isMain = false

    public init(path: String, head: String = "", branch: String? = nil, isBare: Bool = false, isLocked: Bool = false, isPrunable: Bool = false, isMain: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        self.isMain = isMain
    }
}

/// 改动统计。
public struct GitShortStat: Sendable, Equatable {
    public var files = 0
    public var insertions = 0
    public var deletions = 0

    public init(files: Int = 0, insertions: Int = 0, deletions: Int = 0) {
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
    }
}

extension GitParsers {
    /// 解析 `git worktree list --porcelain`。
    /// - Parameter text: 命令输出(空行分隔各工作树)
    /// - Returns: 工作树列表,第一项标记为主检出
    public static func parseWorktrees(_ text: String) -> [GitWorktree] {
        var result: [GitWorktree] = []
        var current: GitWorktree?
        func flush() {
            if var item = current {
                item.isMain = result.isEmpty
                result.append(item)
            }
            current = nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") {
                flush()
                current = GitWorktree(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "bare" {
                current?.isBare = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.isLocked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.isPrunable = true
            }
        }
        flush()
        return result
    }

    /// 解析 `git diff --shortstat` 输出,如 ` 3 files changed, 10 insertions(+), 2 deletions(-)`。
    /// - Parameter text: 命令输出
    public static func parseShortStat(_ text: String) -> GitShortStat {
        var stat = GitShortStat()
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let first = words.first, let number = Int(first) else { continue }
            if part.contains("file") { stat.files = number }
            else if part.contains("insertion") { stat.insertions = number }
            else if part.contains("deletion") { stat.deletions = number }
        }
        return stat
    }
}

extension GitRepository {
    /// 列出全部工作树(含主检出)。
    public func worktrees() async throws -> [GitWorktree] {
        let output = try await git(["worktree", "list", "--porcelain"])
        return GitParsers.parseWorktrees(output.text)
    }

    /// 新建工作树与分支:`git worktree add -b <branch> <path> [<base>]`。
    /// - Parameters:
    ///   - path: 目标目录(绝对路径,不得已存在内容)
    ///   - branch: 新分支名
    ///   - base: 起点提交/分支(默认当前 HEAD)
    /// - Returns: 新工作树对应的仓库
    @discardableResult
    public func addWorktree(at path: String, branch: String, base: String? = nil) async throws -> GitRepository {
        try validateRef(branch)
        if let base { try validateRef(base) }
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw GitError.invalidArgument(String(localized: "无效的路径:\(path)"))
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var args = ["worktree", "add", "-b", branch, path]
        if let base { args.append(base) }
        try await git(args, timeout: 120, lockFree: false)
        Log.git.info("已创建工作树", ["branch": branch, "path": path])
        return GitRepository(root: URL(fileURLWithPath: Self.realPath(path)))
    }

    /// 删除工作树。
    /// - Parameters:
    ///   - path: 工作树目录
    ///   - force: 有未提交改动或被锁定时是否强制删除
    public func removeWorktree(at path: String, force: Bool = false) async throws {
        guard path.hasPrefix("/") else { throw GitError.invalidArgument(String(localized: "无效的路径:\(path)")) }
        try await git(force ? ["worktree", "remove", "--force", path] : ["worktree", "remove", path], timeout: 120, lockFree: false)
        Log.git.info("已删除工作树", ["path": path])
    }

    /// 清理已丢失目录的工作树记录。
    public func pruneWorktrees() async throws {
        try await git(["worktree", "prune"], lockFree: false)
    }

    /// 当前 HEAD 的提交号;空仓库返回 nil。
    public func headCommit() async -> String? {
        guard let output = try? await git(["rev-parse", "--verify", "-q", "HEAD"]) else { return nil }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 两个提交之间的改动统计(`git diff --shortstat from to`)。
    /// - Parameters:
    ///   - base: 起点
    ///   - target: 终点(默认工作区当前 HEAD)
    public func shortStat(from base: String, to target: String = "HEAD") async throws -> GitShortStat {
        try validateRef(base)
        try validateRef(target)
        let output = try await git(["diff", "--shortstat", base, target])
        return GitParsers.parseShortStat(output.text)
    }

    /// 工作区相对某提交的改动统计(含新增未跟踪文件;先 `add -N` 把它们登记为意图添加,不改文件内容)。
    /// - Parameter base: 起点提交
    public func workingTreeStat(from base: String) async throws -> GitShortStat {
        try validateRef(base)
        _ = try? await git(["add", "-N", "."])
        let output = try await git(["diff", "--shortstat", base])
        return GitParsers.parseShortStat(output.text)
    }

    /// 把某分支以非快进方式合并进当前检出。冲突时抛出错误并保留冲突状态,交给 Git 面板解决。
    /// - Parameters:
    ///   - branch: 要合并的分支
    ///   - message: 合并提交说明(nil 使用默认)
    public func merge(branch: String, message: String? = nil) async throws {
        try validateRef(branch)
        var args = ["merge", "--no-ff"]
        if let message { args += ["-m", message] } else { args.append("--no-edit") }
        args.append(branch)
        try await git(args, timeout: 120, lockFree: false)
    }
}
