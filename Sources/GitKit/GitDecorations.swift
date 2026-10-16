// @author ixxxxoooo
// 资源管理器的 Git 装饰:路径 → 状态(文件取自身状态,目录取后代中最醒目的状态)。纯函数,不依赖界面。

import Foundation

/// 装饰类型(决定右侧字母与文字颜色)。
public enum GitDecorationKind: Sendable, Equatable, CaseIterable {
    case conflict, deleted, modified, renamed, added, untracked

    /// 目录冒泡时的优先级,越大越醒目。
    public var priority: Int {
        switch self {
        case .conflict: return 5
        case .deleted: return 4
        case .modified: return 3
        case .renamed, .added: return 2
        case .untracked: return 1
        }
    }

    /// 右侧字母徽标。
    public var letter: String {
        switch self {
        case .conflict: return "!"
        case .deleted: return "D"
        case .modified: return "M"
        case .renamed: return "R"
        case .added: return "A"
        case .untracked: return "U"
        }
    }

    /// 由单个变更推导装饰类型:冲突 > 未跟踪 > 工作区变化 > 暂存区变化。
    /// - Parameter change: 文件变更
    /// - Returns: 装饰类型;没有任何变化时为 nil
    public init?(change: GitFileChange) {
        if change.isConflicted { self = .conflict; return }
        if change.isUntracked { self = .untracked; return }
        guard let kind = change.unstaged ?? change.staged else { return nil }
        switch kind {
        case .added: self = .added
        case .modified, .typeChanged: self = .modified
        case .deleted: self = .deleted
        case .renamed, .copied: self = .renamed
        }
    }
}

/// 装饰索引:绝对路径 → 装饰类型。
public struct GitDecorationIndex: Sendable, Equatable {
    /// 路径 → 类型(包含向上冒泡到各级目录的结果)
    public private(set) var kinds: [String: GitDecorationKind] = [:]

    /// 空索引。
    public init() {}

    /// 由状态快照构建索引。
    /// - Parameters:
    ///   - status: 仓库状态
    ///   - base: 仓库根的绝对路径(与资源管理器使用同一种写法,末尾不带 `/`)
    public init(status: GitStatus, base: String) {
        let root = Self.trimmed(base)
        for change in status.changes {
            guard let kind = GitDecorationKind(change: change) else { continue }
            let path = root + "/" + change.path
            kinds[path] = Self.stronger(kinds[path], kind)
            // 向上冒泡:各级祖先目录取后代中最醒目的状态,止于仓库根(不含根自身)
            var current = path
            while let slash = current.lastIndex(of: "/") {
                current = String(current[..<slash])
                guard current.count > root.count else { break }
                kinds[current] = Self.stronger(kinds[current], kind)
            }
        }
    }

    /// 查询某路径的装饰类型。
    /// - Parameter path: 绝对路径
    /// - Returns: 装饰类型;没有变化为 nil
    public func kind(for path: String) -> GitDecorationKind? { kinds[path] }

    /// 是否没有任何装饰。
    public var isEmpty: Bool { kinds.isEmpty }

    private static func stronger(_ old: GitDecorationKind?, _ new: GitDecorationKind) -> GitDecorationKind {
        guard let old else { return new }
        return new.priority > old.priority ? new : old
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
