// @author ixxxxoooo
// Git 仓库:对 `git` 命令的类型化封装。所有方法在后台子进程执行,不阻塞主线程。
// 路径参数一律放在 `--` 之后,分支名等做合法性校验,避免被解释为选项。

import DiffKit
import Foundation
import OMLog

public struct GitRepository: Sendable {
    /// 仓库根目录(工作区顶层)
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 从任意目录向上发现仓库。
    /// - Parameter path: 目录或文件路径
    /// - Returns: 仓库;不在仓库内时返回 nil
    public static func discover(from path: String) async -> GitRepository? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        let directory = URL(fileURLWithPath: isDir.boolValue ? path : (path as NSString).deletingLastPathComponent)
        guard let output = try? await GitProcess.run(["rev-parse", "--show-toplevel"], in: directory, timeout: 10),
              output.status == 0 else { return nil }
        let top = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? nil : GitRepository(root: URL(fileURLWithPath: top))
    }

    /// 在目录里初始化新仓库(默认分支 main)。
    /// - Parameter directory: 目标目录(必须存在)
    public static func initialize(at directory: String) async throws -> GitRepository {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            throw GitError.invalidArgument(String(localized: "目录不存在:\(directory)"))
        }
        let url = URL(fileURLWithPath: directory)
        let output = try await GitProcess.run(["init", "-b", "main"], in: url, timeout: 15)
        guard output.status == 0 else {
            throw GitError.commandFailed(command: "init", status: output.status, message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let repo = await discover(from: directory) else { throw GitError.notARepository(directory) }
        return repo
    }

    /// 解析符号链接后的真实路径(`/tmp` → `/private/tmp`)。路径不存在时解析其父目录再拼回文件名。
    public static func realPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        return (realPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// 绝对路径相对于仓库根的路径;不在仓库内返回 nil(两侧都先解析符号链接)。
    public func relativePath(of absolute: String) -> String? {
        let rootPath = Self.realPath(root.path)
        let real = Self.realPath(absolute)
        guard real.hasPrefix(rootPath + "/") else { return nil }
        return String(real.dropFirst(rootPath.count + 1))
    }

    // MARK: 内部执行

    @discardableResult
    private func git(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 60, lockFree: Bool = true) async throws -> GitOutput {
        let output = try await GitProcess.run(arguments, in: root, input: input, timeout: timeout, lockFree: lockFree)
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.git.warning("git 命令失败", ["cmd": arguments.first ?? "", "status": "\(output.status)", "message": String(message.prefix(300))])
            throw GitError.commandFailed(command: arguments.first ?? "", status: output.status, message: message)
        }
        return output
    }

    /// 以标准输入喂补丁执行 `git apply`(块级暂存/放弃用)。
    func runApply(_ arguments: [String], patch: Data) async throws {
        try await git(arguments, input: patch, lockFree: false)
    }

    /// 校验分支/引用名:非空、不以 `-` 开头、不含空白与控制字符。
    private func validateRef(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed == name, !name.hasPrefix("-"),
              !name.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "~" || $0 == "^" || $0 == ":" || $0 == "?" || $0 == "*" || $0 == "[" || $0 == "\\" }),
              !name.contains("..") else {
            throw GitError.invalidArgument(String(localized: "无效的名称:\(name)"))
        }
    }

    private func validatePaths(_ paths: [String]) throws {
        guard !paths.isEmpty else { throw GitError.invalidArgument(String(localized: "没有指定文件")) }
        for path in paths where path.isEmpty || path.hasPrefix("/") || path.split(separator: "/").contains("..") {
            throw GitError.invalidArgument(String(localized: "无效的路径:\(path)"))
        }
    }

    // MARK: 状态

    /// 读取仓库状态(含分支、领先/落后、各文件变化)。
    public func status() async throws -> GitStatus {
        let output = try await git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
        return GitParsers.parseStatus(output.stdout)
    }

    /// 未提交改动的行数统计(已跟踪文件相对 HEAD + 未跟踪文本文件的全部行)。
    public func uncommittedStats(untracked: [GitFileChange] = []) async throws -> GitLineStats {
        let hasHead = (try? await git(["rev-parse", "--verify", "-q", "HEAD"])) != nil
        let args = hasHead ? ["diff", "HEAD", "--numstat"] : ["diff", "--cached", "--numstat"]
        var stats = GitParsers.parseNumstat(try await git(args).text)
        for file in untracked {
            let url = root.appendingPathComponent(file.path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.size] as? Int ?? 0) < 1_000_000,
                  let data = try? Data(contentsOf: url), !Self.isBinary(data) else { continue }
            stats.added += String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).count - (data.last == 10 ? 1 : 0)
        }
        return stats
    }

    /// 获取当前未提交差异的统计摘要 (用于生成提交信息)
    public func rawDiffSummary() async throws -> String {
        let staged = (try? await git(["diff", "--cached", "--stat"]).text) ?? ""
        if !staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return staged }
        return (try? await git(["diff", "HEAD", "--stat"]).text) ?? ""
    }

    // MARK: Diff

    /// 数据是否像二进制(前 8000 字节含 NUL)。
    static func isBinary(_ data: Data) -> Bool { data.prefix(8000).contains(0) }

    /// 读取某个版本的文件内容;不存在返回 nil。
    /// - Parameter spec: 如 `HEAD:path`、`:path`(暂存区)
    private func blob(_ spec: String) async -> Data? {
        guard let output = try? await GitProcess.run(["show", spec], in: root, timeout: 30), output.status == 0 else { return nil }
        return output.stdout
    }

    /// 计算单个文件的差异。
    /// - Parameters:
    ///   - path: 相对仓库根的路径
    ///   - scope: 对比范围
    /// - Returns: 差异;任一侧为二进制时返回 nil
    /// 仓库的主分支名 (优先 main、次之 master、次之 origin/main)
    public func defaultBranch() async -> String {
        if (try? await git(["rev-parse", "--verify", "-q", "main"])) != nil { return "main" }
        if (try? await git(["rev-parse", "--verify", "-q", "master"])) != nil { return "master" }
        if (try? await git(["rev-parse", "--verify", "-q", "origin/main"])) != nil { return "origin/main" }
        return "main"
    }

    public func fileDiff(path: String, scope: GitDiffScope = .workingTree) async throws -> FileDiff? {
        try validatePaths([path])
        let worktree = try? Data(contentsOf: root.appendingPathComponent(path))
        let old: Data?, new: Data?
        switch scope {
        case .workingTree: (old, new) = (await blob("HEAD:\(path)"), worktree)
        case .staged: (old, new) = (await blob("HEAD:\(path)"), await blob(":\(path)"))
        case .unstaged: (old, new) = (await blob(":\(path)"), worktree)
        case .mainBranch:
            let main = await defaultBranch()
            (old, new) = (await blob("\(main):\(path)"), worktree)
        }
        if let old, Self.isBinary(old) { return nil }
        if let new, Self.isBinary(new) { return nil }
        return LineDiff.diff(old: old.map { String(decoding: $0, as: UTF8.self) }, new: new.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    /// 某次提交内单个文件的差异(相对第一个父提交)。
    public func fileDiff(path: String, commit: String) async throws -> FileDiff? {
        try validatePaths([path])
        try validateRef(commit)
        let old = await blob("\(commit)^:\(path)")
        let new = await blob("\(commit):\(path)")
        if let old, Self.isBinary(old) { return nil }
        if let new, Self.isBinary(new) { return nil }
        return LineDiff.diff(old: old.map { String(decoding: $0, as: UTF8.self) }, new: new.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    // MARK: 暂存与提交

    public func stage(_ paths: [String]) async throws {
        try validatePaths(paths)
        try await git(["add", "--"] + paths)
    }

    public func stageAll() async throws {
        try await git(["add", "-A"])
    }

    public func unstage(_ paths: [String]) async throws {
        try validatePaths(paths)
        // 尚无提交时 restore --staged 不可用,改用 rm --cached
        if (try? await git(["rev-parse", "--verify", "-q", "HEAD"])) != nil {
            try await git(["restore", "--staged", "--"] + paths)
        } else {
            try await git(["rm", "--cached", "-r", "-q", "--"] + paths)
        }
    }

    public func unstageAll() async throws {
        if (try? await git(["rev-parse", "--verify", "-q", "HEAD"])) != nil {
            try await git(["reset", "-q"])
        } else {
            try await git(["rm", "--cached", "-r", "-q", "--", "."])
        }
    }

    /// 丢弃工作区修改(不可恢复)。
    /// - Parameters:
    ///   - paths: 已跟踪文件
    ///   - untracked: 未跟踪文件(会被删除)
    public func discard(_ paths: [String], untracked: [String] = []) async throws {
        if !paths.isEmpty {
            try validatePaths(paths)
            try await git(["restore", "--worktree", "--"] + paths)
        }
        if !untracked.isEmpty {
            try validatePaths(untracked)
            try await git(["clean", "-f", "-q", "--"] + untracked)
        }
    }

    /// 提交已暂存内容。
    /// - Parameters:
    ///   - message: 提交信息(去除首尾空白后不可为空)
    ///   - amend: 是否修补上一次提交
    /// - Returns: 新提交的完整哈希
    @discardableResult
    public func commit(message: String, amend: Bool = false) async throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.invalidArgument(String(localized: "提交信息不能为空")) }
        var args = ["commit", "-F", "-"]
        if amend { args.append("--amend") }
        try await git(args, input: Data(trimmed.utf8), lockFree: false)
        return try await git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 远程

    public func fetch() async throws {
        try await git(["fetch", "--prune"], timeout: 120)
    }

    /// 拉取并合并(或 rebase)。
    public func pull(rebase: Bool = false) async throws {
        try await git(["pull", rebase ? "--rebase" : "--no-rebase", "--no-edit"], timeout: 180, lockFree: false)
    }

    /// 推送当前分支;没有上游时自动 `--set-upstream` 到第一个远程。
    /// - Parameter status: 最近一次状态(用于判断上游);传 nil 则内部重新读取
    public func push(status: GitStatus? = nil) async throws {
        let current: GitStatus
        if let status { current = status } else { current = try await self.status() }
        if current.upstream != nil {
            try await git(["push"], timeout: 180)
            return
        }
        guard let branch = current.branch else { throw GitError.invalidArgument(String(localized: "游离 HEAD 无法推送,请先创建分支")) }
        let remotes = try await git(["remote"]).text.split(separator: "\n").map(String.init)
        guard let remote = remotes.first(where: { $0 == "origin" }) ?? remotes.first else {
            throw GitError.invalidArgument(String(localized: "没有配置远程仓库"))
        }
        try await git(["push", "--set-upstream", remote, branch], timeout: 180)
    }

    // MARK: 分支

    public func branches() async throws -> [GitBranch] {
        let output = try await git(["for-each-ref", "--format=\(GitParsers.branchFormat)", "--sort=-committerdate", "refs/heads", "refs/remotes"])
        return GitParsers.parseBranches(output.text)
    }

    /// 切换分支(远程分支会创建同名本地分支并跟踪)。
    public func checkout(_ branch: String) async throws {
        try validateRef(branch)
        try await git(["switch", branch], lockFree: false)
    }

    /// 新建分支。
    /// - Parameters:
    ///   - name: 分支名
    ///   - checkout: 是否立即切换
    public func createBranch(_ name: String, checkout: Bool = true) async throws {
        try validateRef(name)
        try await git(checkout ? ["switch", "-c", name] : ["branch", name], lockFree: false)
    }

    public func deleteBranch(_ name: String, force: Bool = false) async throws {
        try validateRef(name)
        try await git(["branch", force ? "-D" : "-d", name])
    }

    // MARK: 历史

    /// 提交历史。
    /// - Parameters:
    ///   - limit: 最大条数
    ///   - path: 仅显示影响该文件的提交
    ///   - all: 是否包含所有分支
    public func log(limit: Int = 200, path: String? = nil, all: Bool = false) async throws -> [GitCommit] {
        guard (try? await git(["rev-parse", "--verify", "-q", "HEAD"])) != nil else { return [] }
        var args = ["log", "--format=\(GitParsers.logFormat)", "-n", "\(max(1, min(limit, 5000)))", "--date-order"]
        if all { args.append("--all") }
        if let path {
            try validatePaths([path])
            args += ["--follow", "--", path]
        }
        return GitParsers.parseLog(try await git(args).text)
    }

    /// 某次提交涉及的文件。
    public func files(in commit: String) async throws -> [GitFileChange] {
        try validateRef(commit)
        let output = try await git(["show", "--name-status", "--format=", "-z", "-M", commit])
        return GitParsers.parseNameStatus(output.stdout)
    }

    /// 逐行追溯(工作区文件;未提交的行哈希全 0)。
    public func blame(path: String) async throws -> [GitBlameLine] {
        try validatePaths([path])
        let output = try await git(["blame", "--porcelain", "--", path], timeout: 60)
        return GitParsers.parseBlame(data: output.stdout)
    }

    // MARK: stash

    public func stashes() async throws -> [GitStash] {
        GitParsers.parseStashes(try await git(["stash", "list", "--format=%gd%x1f%gs"]).text)
    }

    public func stashPush(message: String? = nil, includeUntracked: Bool = true) async throws {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if let message, !message.trimmingCharacters(in: .whitespaces).isEmpty { args += ["-m", message] }
        try await git(args, lockFree: false)
    }

    public func stashPop(index: Int = 0) async throws {
        guard index >= 0 else { throw GitError.invalidArgument(String(localized: "无效的 stash 序号")) }
        try await git(["stash", "pop", "stash@{\(index)}"], lockFree: false)
    }

    public func stashDrop(index: Int) async throws {
        guard index >= 0 else { throw GitError.invalidArgument(String(localized: "无效的 stash 序号")) }
        try await git(["stash", "drop", "stash@{\(index)}"])
    }

    // MARK: 冲突

    /// 解决冲突:采用某一方并标记为已解决。
    public func resolve(_ path: String, with resolution: GitConflictResolution) async throws {
        try validatePaths([path])
        try await git(["checkout", resolution == .ours ? "--ours" : "--theirs", "--", path])
        try await git(["add", "--", path])
    }

    /// 标记文件为已解决(用户手动编辑后)。
    public func markResolved(_ path: String) async throws {
        try validatePaths([path])
        try await git(["add", "--", path])
    }

    /// 中止进行中的合并。
    public func abortMerge() async throws {
        try await git(["merge", "--abort"])
    }
}
