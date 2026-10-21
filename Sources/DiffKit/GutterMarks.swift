// @author ixxxxoooo
// 行号栏的改动标记(类似 VS Code 的 diff gutter):由文件差异推出每个新文件行是「新增 / 修改 / 删除处」。
// 无视图;编辑器按行号(0 起始)取标记着色。

import Foundation

/// 行号栏改动标记。
public enum GutterMark: Sendable, Equatable {
    /// 新增的行
    case added
    /// 修改的行(对应旧文件里被替换的行)
    case modified
    /// 此处之前删除了若干行(标在其后的那一行上)
    case removed
}

public extension LineDiff {
    /// 由差异推出行号栏标记。
    /// - Parameter diff: 文件差异
    /// - Returns: 新文件行号(0 起始)→ 标记
    static func gutterMarks(for diff: FileDiff) -> [Int: GutterMark] {
        var marks: [Int: GutterMark] = [:]
        for hunk in diff.hunks {
            let lines = hunk.lines
            var index = 0
            while index < lines.count {
                guard lines[index].kind != .context else { index += 1; continue }
                // 一段连续的非上下文行:先删后增 = 修改
                var removed = 0
                var added: [Int] = []
                while index < lines.count, lines[index].kind != .context {
                    if lines[index].kind == .removed { removed += 1 }
                    else if let number = lines[index].newNumber { added.append(number - 1) }
                    index += 1
                }
                if added.isEmpty {
                    // 纯删除:标在下一个新文件行(没有就标在上一行)
                    if index < lines.count, let next = lines[index].newNumber { marks[next - 1] = marks[next - 1] ?? .removed }
                    else if let last = hunk.lines.last(where: { $0.newNumber != nil })?.newNumber { marks[last - 1] = marks[last - 1] ?? .removed }
                } else {
                    for (offset, line) in added.enumerated() { marks[line] = offset < removed ? .modified : .added }
                }
            }
        }
        return marks
    }
}
