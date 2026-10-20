// @author ixxxxoooo
// 资源管理器文件操作的撤销栈:记录新建/重命名/移动/复制/移到废纸篓,并按相反顺序回退(纯逻辑,可测试)。

import Foundation

/// 一次可撤销的底层文件操作。
public enum FileOp: Sendable, Equatable {
    /// 移动或重命名(撤销:把 `to` 移回 `from`)
    case move(from: String, to: String)
    /// 新建文件/文件夹或复制出的新项目(撤销:把它移到废纸篓)
    case created(path: String)
    /// 移到废纸篓(撤销:把废纸篓里的 `trashed` 放回 `original`)
    case trashed(original: String, trashed: String)
}

/// 一组原子的用户操作(如一次拖放含多个文件),撤销时整组回退。
public struct FileOpGroup: Sendable, Equatable {
    /// 操作说明(用于日志与提示)
    public let title: String
    /// 按执行顺序记录的底层操作
    public let ops: [FileOp]

    /// - Parameters:
    ///   - title: 操作说明
    ///   - ops: 按执行顺序的底层操作
    public init(title: String, ops: [FileOp]) {
        self.title = title
        self.ops = ops
    }
}

/// 撤销栈(值类型,由调用方放在主线程持有)。
public struct FileOpHistory: Sendable {
    /// 最多保留的操作组数
    public static let capacity = 50
    private var groups: [FileOpGroup] = []

    public init() {}

    /// 是否有可撤销的操作。
    public var canUndo: Bool { !groups.isEmpty }

    /// 记录一组操作;空组忽略,超出容量丢弃最旧的。
    /// - Parameter group: 操作组
    public mutating func push(_ group: FileOpGroup) {
        guard !group.ops.isEmpty else { return }
        groups.append(group)
        if groups.count > Self.capacity { groups.removeFirst(groups.count - Self.capacity) }
    }

    /// 取出最近一组操作(从栈中移除)。
    /// - Returns: 最近的操作组;栈空为 nil
    public mutating func popLast() -> FileOpGroup? { groups.popLast() }
}

/// 回退操作组的执行器(会做磁盘操作,请在后台线程调用)。
public enum FileOpReverter {
    /// 按相反顺序回退一组操作;某一步失败不中断其余步骤。
    /// - Parameter group: 要回退的操作组
    /// - Returns: 失败说明列表(全部成功为空)
    public nonisolated static func revert(_ group: FileOpGroup) -> [String] {
        let fm = FileManager.default
        var failures: [String] = []
        for op in group.ops.reversed() {
            do {
                switch op {
                case .move(let from, let to):
                    try restore(from: to, to: from, fm: fm)
                case .trashed(let original, let trashed):
                    try restore(from: trashed, to: original, fm: fm)
                case .created(let path):
                    guard fm.fileExists(atPath: path) else { continue }
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                }
            } catch {
                failures.append("\((op.displayPath as NSString).lastPathComponent):\(error.localizedDescription)")
            }
        }
        return failures
    }

    /// 把 `source` 移到 `destination`(目标已存在或源已不在时报错,不覆盖)。
    private nonisolated static func restore(from source: String, to destination: String, fm: FileManager) throws {
        guard fm.fileExists(atPath: source) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: String(localized: "项目已不在原位置")])
        }
        guard !fm.fileExists(atPath: destination) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: String(localized: "原位置已有同名项目")])
        }
        try fm.moveItem(atPath: source, toPath: destination)
    }
}

extension FileOp {
    /// 用于错误提示的路径。
    var displayPath: String {
        switch self {
        case .move(_, let to): return to
        case .created(let path): return path
        case .trashed(let original, _): return original
        }
    }
}
