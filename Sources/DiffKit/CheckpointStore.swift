// @author ixxxxoooo
// 检查点:记录每一轮对话中 Agent 修改过的文件的原始内容,支持整文件或按块回退。
// 回退前会校验磁盘上的当前内容仍等于 Agent 写入后的内容,否则报告冲突而不覆盖用户的手工修改。

import Foundation

/// 回退结果。
public enum RevertOutcome: Sendable, Equatable {
    /// 已回退
    case reverted
    /// 文件已被其它修改改动,未执行回退
    case conflict
    /// 没有对应的检查点
    case notFound
    /// 写入失败
    case failed(String)
}

/// 单个文件的检查点。
public struct FileCheckpoint: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    /// 本轮开始前的内容;nil 表示文件原本不存在
    public var original: String?
    /// Agent 写入后的内容(用于冲突检测)
    public var expected: String
    public var turn: Int
}

/// 检查点存储(内存)。
public actor CheckpointStore {
    private var entries: [String: FileCheckpoint] = [:]
    private var order: [String] = []

    public init() {}

    /// 记录一次文件改动。同一轮同一文件只保留第一次的原始内容,并持续更新期望内容。
    /// - Parameters:
    ///   - turn: 轮次编号
    ///   - path: 绝对路径
    ///   - oldText: 改动前内容(nil 表示新建)
    ///   - newText: 改动后内容
    public func record(turn: Int, path: String, oldText: String?, newText: String) {
        if var existing = entries[path], existing.turn == turn {
            existing.expected = newText
            entries[path] = existing
        } else {
            if entries[path] == nil { order.append(path) }
            entries[path] = FileCheckpoint(path: path, original: oldText, expected: newText, turn: turn)
        }
    }

    /// 某一轮的全部检查点。
    /// - Parameter turn: 轮次
    public func checkpoints(turn: Int) -> [FileCheckpoint] {
        order.compactMap { entries[$0] }.filter { $0.turn == turn }
    }

    /// 全部检查点(按首次记录顺序)。
    public func all() -> [FileCheckpoint] {
        order.compactMap { entries[$0] }
    }

    /// 回退文件。
    /// - Parameters:
    ///   - path: 文件路径
    ///   - hunks: 仅回退这些块;nil 表示整文件回退到原始内容
    /// - Returns: 回退结果
    public func revert(path: String, hunks: Set<Int>? = nil) -> RevertOutcome {
        guard var checkpoint = entries[path] else { return .notFound }
        let url = URL(fileURLWithPath: path)
        let current = try? String(contentsOf: url, encoding: .utf8)
        guard current == checkpoint.expected else { return .conflict }

        do {
            if let hunks {
                let diff = LineDiff.diff(old: checkpoint.original, new: checkpoint.expected)
                let result = LineDiff.revert(hunks: hunks, in: diff)
                try result.write(to: url, atomically: true, encoding: .utf8)
                checkpoint.expected = result
                entries[path] = checkpoint
            } else if let original = checkpoint.original {
                try original.write(to: url, atomically: true, encoding: .utf8)
                entries[path] = nil
                order.removeAll { $0 == path }
            } else {
                try FileManager.default.removeItem(at: url)
                entries[path] = nil
                order.removeAll { $0 == path }
            }
            return .reverted
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 回退某一轮的全部文件改动。
    /// - Parameter turn: 轮次
    /// - Returns: 每个文件的结果
    public func revertTurn(_ turn: Int) -> [String: RevertOutcome] {
        var results: [String: RevertOutcome] = [:]
        for checkpoint in checkpoints(turn: turn) {
            results[checkpoint.path] = revert(path: checkpoint.path)
        }
        return results
    }

    /// 清空检查点(例如新对话)。
    public func reset() {
        entries.removeAll()
        order.removeAll()
    }
}
