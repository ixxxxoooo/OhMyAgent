// @author ixxxxoooo
// 块级补丁:把 DiffKit 的一个差异块还原成标准 unified 补丁,交给 `git apply` 做块级暂存/取消暂存/放弃。
// 纯函数,不接触文件系统。

import DiffKit
import Foundation

/// 块级操作。
public enum GitHunkAction: Sendable, Equatable {
    /// 暂存此块(工作区 → 暂存区),对应「未暂存」范围的差异
    case stage
    /// 取消暂存此块(撤销暂存区的这一块),对应「已暂存」范围的差异
    case unstage
    /// 放弃此块的工作区修改,对应「未暂存」范围的差异(不可恢复)
    case discard

    /// `git apply` 参数。
    var arguments: [String] {
        switch self {
        case .stage: return ["apply", "--cached", "--recount", "-"]
        case .unstage: return ["apply", "--cached", "-R", "--recount", "-"]
        case .discard: return ["apply", "-R", "--recount", "-"]
        }
    }
}

/// 补丁生成。
public enum HunkPatch {
    /// 生成单个块的补丁文本。
    /// - Parameters:
    ///   - path: 相对仓库根的路径
    ///   - diff: 该文件的差异(用于判断结尾换行)
    ///   - hunkID: 块 ID
    /// - Returns: 补丁文本;块不存在时为 nil
    public static func make(path: String, diff: FileDiff, hunkID: Int) -> String? {
        guard let hunk = diff.hunks.first(where: { $0.id == hunkID }) else { return nil }
        var text = "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n"
        text += hunk.header + "\n"
        for line in hunk.lines {
            switch line.kind {
            case .context: text += " " + line.text + "\n"
            case .added: text += "+" + line.text + "\n"
            case .removed: text += "-" + line.text + "\n"
            }
            let oldLast = line.oldNumber == diff.oldLines.count && !diff.oldTrailingNewline
            let newLast = line.newNumber == diff.newLines.count && !diff.newTrailingNewline
            let needsMarker: Bool
            switch line.kind {
            case .removed: needsMarker = oldLast
            case .added: needsMarker = newLast
            case .context: needsMarker = oldLast || newLast
            }
            if needsMarker { text += "\\ No newline at end of file\n" }
        }
        return text
    }
}

extension GitRepository {
    /// 对单个块执行暂存/取消暂存/放弃。
    /// - Parameters:
    ///   - action: 操作
    ///   - path: 相对仓库根的路径
    ///   - diff: 与操作范围一致的文件差异(`.stage/.discard` 用「未暂存」,`.unstage` 用「已暂存」)
    ///   - hunkID: 块 ID
    public func applyHunk(_ action: GitHunkAction, path: String, diff: FileDiff, hunkID: Int) async throws {
        guard let patch = HunkPatch.make(path: path, diff: diff, hunkID: hunkID) else {
            throw GitError.invalidArgument(String(localized: "差异块已不存在,请刷新后重试"))
        }
        try await runApply(action.arguments, patch: Data(patch.utf8))
    }
}
