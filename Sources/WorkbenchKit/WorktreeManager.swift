// @author ixxxxoooo
// 工作树管理(对照 Cursor Worktrees):每个任务在 `~/.ohmyagent/worktrees/<仓库哈希>/<名称>` 的隔离检出里运行。
// - 命名、路径、`.oma/worktrees.json`(兼容 `.cursor/worktrees.json`)初始化脚本、清理策略都是纯逻辑,可单测;
// - 创建/应用/删除经 GitKit 的 `git worktree`;应用 = 先提交工作树里的改动,再以非快进合并回主检出(冲突交给 Git 面板);
// - 工作树在工作台里表现为带 `WorktreeLink` 的项目,会话、标签、历史沿用项目机制。

import ChatKit
import Foundation
import GitKit
import OMLog

/// 初始化脚本。
public struct WorktreeSetup: Equatable, Sendable {
    /// 依次执行的 shell 命令(任一失败即停止)
    public var commands: [String]

    public init(commands: [String]) {
        self.commands = commands
    }
}

/// 一个受管理的工作树及其状态(清理策略的输入)。
public struct ManagedWorktree: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var branch: String
    /// 目录最近修改时间
    public var modified: Date
    /// 是否有未提交改动
    public var isDirty: Bool

    public init(path: String, branch: String, modified: Date, isDirty: Bool) {
        self.path = path
        self.branch = branch
        self.modified = modified
        self.isDirty = isDirty
    }
}

/// 创建结果。
public struct WorktreeCreated: Equatable, Sendable {
    public var path: String
    public var branch: String
    /// 创建时主检出的提交
    public var base: String
}

/// 工作树错误。
public enum WorktreeError: Error, Equatable, LocalizedError {
    case notARepository
    case multiRoot
    case originDirty
    case noOrigin

    public var errorDescription: String? {
        switch self {
        case .notARepository: String(localized: "当前项目不是 Git 仓库,无法使用工作树。")
        case .multiRoot: String(localized: "多文件夹工作区暂不支持工作树。")
        case .originDirty: String(localized: "主检出有未提交的改动,请先提交或暂存后再应用工作树。")
        case .noOrigin: String(localized: "找不到这个工作树对应的原项目。")
        }
    }
}

public enum WorktreeManager {
    /// 工作树根目录:`~/.ohmyagent/worktrees`。
    /// - Parameter home: 用户主目录(测试可注入)
    public static func root(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".ohmyagent/worktrees")
    }

    /// 仓库路径的稳定短哈希(FNV-1a,8 位十六进制)。
    /// - Parameter path: 仓库根目录
    public static func repoHash(_ path: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(format: "%08x", hash)
    }

    /// 把任意标题转成可作目录与分支名的短横线 slug(只保留 ASCII 字母数字;全是其他字符时为 `task`)。
    /// - Parameter text: 标题
    public static func slug(_ text: String) -> String {
        var out = ""
        var lastDash = true
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "task" : String(trimmed.prefix(32))
    }

    /// 生成不与已有名称冲突的工作树名。
    /// - Parameters:
    ///   - title: 标题或用户输入
    ///   - existing: 已被占用的名称
    public static func makeName(title: String, existing: Set<String>) -> String {
        let base = slug(title)
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    /// 工作树目录。
    /// - Parameters:
    ///   - repoRoot: 主检出根目录
    ///   - name: 工作树名
    ///   - home: 用户主目录
    public static func destination(repoRoot: String, name: String, home: String = NSHomeDirectory()) -> String {
        (root(home: home) as NSString).appendingPathComponent(repoHash(repoRoot) + "/" + name)
    }

    /// 工作树分支名:`oma/<名称>`。
    public static func branchName(for name: String) -> String { "oma/\(name)" }

    /// 路径是否位于受管理的工作树根目录之下。
    public static func isManaged(path: String, home: String = NSHomeDirectory()) -> Bool {
        let base = root(home: home)
        // Git 报告的是真实路径(如 /private/var),主目录可能经符号链接,两种写法都要认
        return path.hasPrefix(base + "/") || path.hasPrefix(GitRepository.realPath(base) + "/")
    }

    // MARK: 初始化脚本

    /// 读取初始化脚本配置:`.oma/worktrees.json`,不存在时回退 `.cursor/worktrees.json`。
    /// 键 `setup-worktree-unix` 优先于 `setup-worktree`;值为命令数组,或脚本路径(相对仓库根目录,存在则执行该脚本)。
    /// - Parameter repoRoot: 主检出根目录
    /// - Returns: 脚本;没有配置时为 nil
    public static func loadSetup(repoRoot: String) -> WorktreeSetup? {
        for name in [".oma/worktrees.json", ".cursor/worktrees.json"] {
            let path = (repoRoot as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for key in ["setup-worktree-unix", "setup-worktree"] {
                guard let value = object[key] else { continue }
                let commands = parseCommands(value, repoRoot: repoRoot)
                if !commands.isEmpty { return WorktreeSetup(commands: commands) }
            }
        }
        return nil
    }

    static func parseCommands(_ value: Any, repoRoot: String) -> [String] {
        if let list = value as? [String] { return list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let script = text.hasPrefix("/") ? text : (repoRoot as NSString).appendingPathComponent(text)
        if FileManager.default.fileExists(atPath: script) { return ["/bin/sh " + shellQuote(script)] }
        return [text]
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// 在工作树里依次执行初始化命令,注入 `ROOT_WORKTREE_PATH`(主检出路径)。
    /// - Parameters:
    ///   - setup: 脚本
    ///   - worktreePath: 工作树目录(命令的工作目录)
    ///   - rootPath: 主检出路径
    ///   - onOutput: 每行输出回调(写入输出面板的「Worktrees Setup」)
    /// - Returns: 全部成功为 true;某条命令失败即停止并返回 false
    @discardableResult
    public static func runSetup(_ setup: WorktreeSetup, worktreePath: String, rootPath: String, onOutput: @Sendable @escaping (String) -> Void = { _ in }) async -> Bool {
        for command in setup.commands {
            onOutput("$ \(command)")
            let status = await runShell(command, directory: worktreePath, rootPath: rootPath, onOutput: onOutput)
            if status != 0 {
                onOutput("exit \(status)")
                Log.git.warning("工作树初始化命令失败", ["command": String(command.prefix(120)), "status": "\(status)"])
                return false
            }
        }
        return true
    }

    private static func runShell(_ command: String, directory: String, rootPath: String, onOutput: @Sendable @escaping (String) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            var environment = ProcessInfo.processInfo.environment
            environment["ROOT_WORKTREE_PATH"] = rootPath
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) { onOutput(String(line)) }
            }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }
            do { try process.run() } catch {
                onOutput("无法启动命令:\(error.localizedDescription)")
                continuation.resume(returning: 127)
            }
        }
    }

    // MARK: 清理策略

    /// 超出数量上限时应清理的工作树:从最旧的开始,只挑没有未提交改动的。
    /// - Parameters:
    ///   - items: 全部受管理的工作树
    ///   - maxCount: 数量上限
    /// - Returns: 建议清理的工作树(最旧在前);数量不超限返回空
    public static func cleanupCandidates(_ items: [ManagedWorktree], maxCount: Int) -> [ManagedWorktree] {
        let excess = items.count - max(maxCount, 1)
        guard excess > 0 else { return [] }
        return Array(items.filter { !$0.isDirty }.sorted { $0.modified < $1.modified }.prefix(excess))
    }

    // MARK: 操作

    /// 创建工作树并运行初始化脚本。
    /// - Parameters:
    ///   - repo: 主检出仓库
    ///   - title: 标题(生成名称)
    ///   - home: 用户主目录
    ///   - onOutput: 初始化脚本输出
    /// - Returns: 创建结果
    public static func create(in repo: GitRepository, title: String, home: String = NSHomeDirectory(), onOutput: @Sendable @escaping (String) -> Void = { _ in }) async throws -> WorktreeCreated {
        guard let base = await repo.headCommit() else { throw WorktreeError.notARepository }
        let existing = Set(((try? await repo.worktrees()) ?? []).map { ($0.path as NSString).lastPathComponent })
        let name = makeName(title: title, existing: existing)
        let path = destination(repoRoot: repo.root.path, name: name, home: home)
        let created = try await repo.addWorktree(at: path, branch: branchName(for: name), base: base)
        if let setup = loadSetup(repoRoot: repo.root.path) {
            await runSetup(setup, worktreePath: created.root.path, rootPath: repo.root.path, onOutput: onOutput)
        }
        return WorktreeCreated(path: created.root.path, branch: branchName(for: name), base: base)
    }

    /// 应用工作树:先提交其中的改动,再合并回主检出。主检出有未提交改动时拒绝。
    /// - Parameters:
    ///   - origin: 主检出仓库
    ///   - worktreePath: 工作树目录
    ///   - branch: 工作树分支
    public static func apply(origin: GitRepository, worktreePath: String, branch: String) async throws {
        let status = try await origin.status()
        guard status.changes.isEmpty else { throw WorktreeError.originDirty }
        let worktree = GitRepository(root: URL(fileURLWithPath: worktreePath))
        if !(try await worktree.status().changes.isEmpty) {
            try await worktree.stageAll()
            _ = try await worktree.commit(message: "OhMyAgent worktree: \(branch)")
        }
        try await origin.merge(branch: branch, message: "Merge worktree \(branch)")
    }

    /// 删除工作树及其分支(分支删除失败不影响结果,如尚未合并)。
    /// - Parameters:
    ///   - origin: 主检出仓库
    ///   - worktreePath: 工作树目录
    ///   - branch: 分支
    ///   - deleteBranch: 是否同时删除分支
    public static func remove(origin: GitRepository, worktreePath: String, branch: String?, deleteBranch: Bool) async throws {
        try await origin.removeWorktree(at: worktreePath, force: true)
        try? await origin.pruneWorktrees()
        if deleteBranch, let branch { try? await origin.deleteBranch(branch, force: true) }
    }

    /// 列出某仓库下受管理的工作树及其状态。
    /// - Parameters:
    ///   - repo: 主检出仓库
    ///   - home: 用户主目录
    public static func listManaged(in repo: GitRepository, home: String = NSHomeDirectory()) async -> [ManagedWorktree] {
        guard let all = try? await repo.worktrees() else { return [] }
        var result: [ManagedWorktree] = []
        for item in all where !item.isMain && isManaged(path: item.path, home: home) && !item.isPrunable {
            let attributes = try? FileManager.default.attributesOfItem(atPath: item.path)
            let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
            let dirty = !((try? await GitRepository(root: URL(fileURLWithPath: item.path)).status().changes.isEmpty) ?? true)
            result.append(ManagedWorktree(path: item.path, branch: item.branch ?? "", modified: modified, isDirty: dirty))
        }
        return result
    }

    /// 按策略清理超限的工作树。
    /// - Parameters:
    ///   - repo: 主检出仓库
    ///   - maxCount: 数量上限
    /// - Returns: 已删除的工作树
    @discardableResult
    public static func cleanup(in repo: GitRepository, maxCount: Int, home: String = NSHomeDirectory()) async -> [ManagedWorktree] {
        let items = await listManaged(in: repo, home: home)
        let doomed = cleanupCandidates(items, maxCount: maxCount)
        for item in doomed {
            try? await remove(origin: repo, worktreePath: item.path, branch: item.branch.isEmpty ? nil : item.branch, deleteBranch: true)
            Log.git.info("已按策略清理工作树", ["path": item.path])
        }
        return doomed
    }
}
