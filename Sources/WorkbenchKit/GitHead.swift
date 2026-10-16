// @author ixxxxoooo
// 读取项目当前 Git 分支:直接解析 .git/HEAD(不启动子进程),支持 worktree 与 submodule 的 gitdir 间接文件。

import Foundation

/// Git HEAD 状态。
public enum GitHead: Equatable, Sendable {
    /// 位于某个分支
    case branch(String)
    /// 游离 HEAD(保存短哈希)
    case detached(String)

    /// 界面展示名:分支名或短哈希。
    public var displayName: String {
        switch self {
        case .branch(let name): return name
        case .detached(let hash): return hash
        }
    }

    /// 读取目录所在仓库的 HEAD;目录不在 Git 仓库中或文件无法解析时返回 nil。
    /// - Parameter directory: 项目目录(会向上逐级查找 `.git`)
    public static func read(at directory: URL) -> GitHead? {
        guard let gitDir = locateGitDirectory(from: directory) else { return nil }
        guard let raw = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        return parse(raw)
    }

    /// 解析 HEAD 文件内容。
    /// - Parameter text: `ref: refs/heads/main` 或 40 位提交哈希
    public static func parse(_ text: String) -> GitHead? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let prefix = "refs/heads/"
            if ref.hasPrefix(prefix), ref.count > prefix.count { return .branch(String(ref.dropFirst(prefix.count))) }
            return ref.isEmpty ? nil : .branch(ref)
        }
        let isHash = line.count >= 7 && line.allSatisfy { $0.isHexDigit }
        return isHash ? .detached(String(line.prefix(7))) : nil
    }

    /// 向上查找 `.git`;若为文件(worktree/submodule)则跟随其中的 `gitdir:` 指向。
    static func locateGitDirectory(from start: URL) -> URL? {
        var current = start.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<40 {
            let candidate = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir) {
                if isDir.boolValue { return candidate }
                if let text = try? String(contentsOf: candidate, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let path = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : current.appendingPathComponent(path)
                    return url.standardizedFileURL
                }
                return nil
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }
}
