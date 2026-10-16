// @author ixxxxoooo
// Git 数据模型:状态、分支、提交、blame、stash。均为值类型,可跨并发边界传递。

import Foundation

/// 变更类型(对应 porcelain 的 XY 字符)。
public enum GitChangeKind: Sendable, Hashable {
    case added, modified, deleted, renamed, copied, typeChanged

    /// 由 porcelain 状态字符解析;`.` 或空格表示无变化,返回 nil。
    init?(code: Character) {
        switch code {
        case "A": self = .added
        case "M": self = .modified
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        default: return nil
        }
    }

    /// 单字母标记(界面右侧徽标)。
    public var badge: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        }
    }
}

/// 单个文件的状态。
public struct GitFileChange: Sendable, Hashable, Identifiable {
    public var id: String { path }
    /// 相对仓库根的路径
    public var path: String
    /// 重命名/复制前的路径
    public var originalPath: String?
    /// 暂存区相对 HEAD 的变化
    public var staged: GitChangeKind?
    /// 工作区相对暂存区的变化
    public var unstaged: GitChangeKind?
    /// 是否未跟踪
    public var isUntracked: Bool
    /// 是否处于冲突
    public var isConflicted: Bool

    public init(path: String, originalPath: String? = nil, staged: GitChangeKind? = nil, unstaged: GitChangeKind? = nil,
                isUntracked: Bool = false, isConflicted: Bool = false) {
        self.path = path
        self.originalPath = originalPath
        self.staged = staged
        self.unstaged = unstaged
        self.isUntracked = isUntracked
        self.isConflicted = isConflicted
    }
}

/// 仓库状态快照。
public struct GitStatus: Sendable, Equatable {
    /// 当前分支名;游离 HEAD 时为 nil
    public var branch: String?
    /// 当前提交(尚无提交时为 nil)
    public var headOID: String?
    /// 上游分支(如 `origin/main`)
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var changes: [GitFileChange] = []

    public init() {}

    public var stagedChanges: [GitFileChange] { changes.filter { $0.staged != nil && !$0.isConflicted } }
    public var unstagedChanges: [GitFileChange] { changes.filter { $0.unstaged != nil && !$0.isConflicted && !$0.isUntracked } }
    public var untrackedChanges: [GitFileChange] { changes.filter(\.isUntracked) }
    public var conflicts: [GitFileChange] { changes.filter(\.isConflicted) }
    public var isClean: Bool { changes.isEmpty }
    public var isDetached: Bool { branch == nil && headOID != nil }
}

/// 新增/删除行数统计。
public struct GitLineStats: Sendable, Equatable {
    public var added: Int
    public var removed: Int
    public init(added: Int = 0, removed: Int = 0) {
        self.added = added
        self.removed = removed
    }
}

/// 分支。
public struct GitBranch: Sendable, Hashable, Identifiable {
    public var id: String { (isRemote ? "remotes/" : "heads/") + name }
    public var name: String
    public var isCurrent: Bool
    public var isRemote: Bool
    public var upstream: String?
    public var hash: String
    public var subject: String

    public init(name: String, isCurrent: Bool, isRemote: Bool, upstream: String?, hash: String, subject: String) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
        self.upstream = upstream
        self.hash = hash
        self.subject = subject
    }
}

/// 提交。
public struct GitCommit: Sendable, Hashable, Identifiable {
    public var id: String { hash }
    public var hash: String
    public var parents: [String]
    public var author: String
    public var email: String
    public var date: Date
    public var subject: String
    /// 指向该提交的引用(分支/标签),如 `HEAD -> main`、`origin/main`、`tag: v1`
    public var refs: [String]

    public init(hash: String, parents: [String], author: String, email: String, date: Date, subject: String, refs: [String]) {
        self.hash = hash
        self.parents = parents
        self.author = author
        self.email = email
        self.date = date
        self.subject = subject
        self.refs = refs
    }

    public var shortHash: String { String(hash.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
}

/// blame 的一行。
public struct GitBlameLine: Sendable, Hashable {
    public var lineNumber: Int
    public var hash: String
    public var author: String
    public var date: Date
    public var summary: String
    public var text: String
    /// 是否尚未提交
    public var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}

/// stash 条目。
public struct GitStash: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var message: String
}

/// Diff 对比范围。
public enum GitDiffScope: Sendable, Hashable {
    /// 工作区相对 HEAD(含已暂存与未暂存)
    case workingTree
    /// 暂存区相对 HEAD
    case staged
    /// 工作区相对暂存区
    case unstaged
}

/// 冲突解决方式。
public enum GitConflictResolution: Sendable {
    /// 保留当前分支(ours)
    case ours
    /// 采用对方(theirs)
    case theirs
}

/// Git 操作错误。
public enum GitError: Error, Sendable, Equatable, LocalizedError {
    case notARepository(String)
    case launchFailed(String)
    case commandFailed(command: String, status: Int32, message: String)
    case invalidArgument(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .notARepository(let path): return String(localized: "不是 Git 仓库:\(path)")
        case .launchFailed(let reason): return String(localized: "无法启动 git:\(reason)")
        case .commandFailed(_, _, let message): return message.isEmpty ? String(localized: "git 命令执行失败") : message
        case .invalidArgument(let reason): return reason
        case .timedOut(let command): return String(localized: "git \(command) 超时")
        }
    }
}
