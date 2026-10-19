// @author ixxxxoooo
// 资源管理器拖放:把拖入的文件/文件夹规划成移动或复制(纯逻辑,无文件操作、无视图)。
// 规则对齐 VS Code:工作区内拖动 = 移动;从外部(Finder 等)拖入 = 复制。

import Foundation

/// 一次拖放中的单个文件操作。
public struct ExplorerTransfer: Equatable, Sendable {
    /// 操作类型。
    public enum Kind: Equatable, Sendable {
        /// 工作区内移动位置
        case move
        /// 从外部复制进来
        case copy
    }

    /// 源路径(标准化)
    public let source: String
    /// 目标路径(目标文件夹 + 源文件名)
    public let destination: String
    public let kind: Kind

    public init(source: String, destination: String, kind: Kind) {
        self.source = source
        self.destination = destination
        self.kind = kind
    }
}

/// 拖放规划结果。
public struct ExplorerDropPlan: Equatable, Sendable {
    /// 要执行的操作
    public var transfers: [ExplorerTransfer] = []
    /// 因「移到自身或其子文件夹」被拒绝的源路径
    public var rejected: [String] = []

    public init(transfers: [ExplorerTransfer] = [], rejected: [String] = []) {
        self.transfers = transfers
        self.rejected = rejected
    }

    /// 规划拖放。
    /// - Parameters:
    ///   - sources: 拖入的文件/文件夹路径
    ///   - directory: 落点文件夹
    ///   - workspaceRoots: 当前项目的根目录(主目录与附加文件夹);在其中的源为移动,其余为复制
    /// - Returns: 规划结果(已在原位置的移动被忽略;同时拖动父子目录时只保留父目录)
    public static func make(sources: [String], into directory: String, workspaceRoots: [String]) -> ExplorerDropPlan {
        let target = standardize(directory)
        let roots = workspaceRoots.map(standardize)
        var unique: [String] = []
        for path in sources.map(standardize) where !path.isEmpty && path != "/" && !unique.contains(path) { unique.append(path) }
        // 同时拖了某个目录和它里面的文件:只处理外层目录
        let outermost = unique.filter { path in !unique.contains { $0 != path && path.hasPrefix($0 + "/") } }
        var plan = ExplorerDropPlan()
        for source in outermost {
            if target == source || target.hasPrefix(source + "/") {
                plan.rejected.append(source)
                continue
            }
            let inWorkspace = roots.contains { source == $0 || source.hasPrefix($0 + "/") }
            let parent = (source as NSString).deletingLastPathComponent
            if inWorkspace, parent == target { continue }
            let destination = (target as NSString).appendingPathComponent((source as NSString).lastPathComponent)
            plan.transfers.append(ExplorerTransfer(source: source, destination: destination, kind: inWorkspace ? .move : .copy))
        }
        return plan
    }

    /// 标准化路径(去掉 `.`/`..` 与末尾斜杠)。
    private static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

public extension DockLayout {
    /// 文件或文件夹被移动后,把指向旧位置(及其内部)的文件标签改指向新位置,标签与分屏布局保持不变。
    /// - Parameters:
    ///   - source: 旧路径
    ///   - destination: 新路径
    mutating func retargetFiles(from source: String, to destination: String) {
        for tab in allTabs {
            guard case .file(let path) = tab.kind else { continue }
            let moved: String
            if path == source {
                moved = destination
            } else if path.hasPrefix(source + "/") {
                moved = destination + path.dropFirst(source.count)
            } else {
                continue
            }
            retarget(tab.id, kind: .file(path: moved), title: (moved as NSString).lastPathComponent)
        }
    }
}
