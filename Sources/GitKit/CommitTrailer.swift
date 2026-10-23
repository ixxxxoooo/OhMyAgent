// @author ixxxxoooo
// 提交说明署名:可选地在提交说明末尾追加 `Co-authored-by` 尾注。

import Foundation

/// 提交尾注工具。
public enum CommitTrailer {
    /// OhMyAgent 的署名行。
    public static let coAuthorLine = "Co-authored-by: OhMyAgent <noreply@ohmyagent.app>"

    /// 在说明末尾追加署名(已含同一署名时不重复)。
    /// - Parameters:
    ///   - message: 原提交说明
    ///   - enabled: 是否追加
    /// - Returns: 处理后的说明
    public static func apply(to message: String, enabled: Bool) -> String {
        apply(to: message, lines: enabled ? [coAuthorLine] : [])
    }

    /// 在说明末尾追加若干尾注行(说明里已有的行不重复,比较忽略大小写)。
    /// - Parameters:
    ///   - message: 原提交说明
    ///   - lines: 要追加的尾注行(如 `Co-authored-by: A <a@b.c>`)
    /// - Returns: 处理后的说明;说明为空时返回空串
    public static func apply(to message: String, lines: [String]) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let existing = Set(trimmed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let fresh = lines.filter { !existing.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return trimmed }
        // 已有尾注块(最后一段全是 `Key: value`)则紧接着写,否则空一行
        let lastBlock = trimmed.components(separatedBy: "\n\n").last ?? ""
        let isTrailerBlock = trimmed.contains("\n\n") && !lastBlock.isEmpty
            && lastBlock.split(separator: "\n").allSatisfy { $0.range(of: #"^[A-Za-z-]+: .+"#, options: .regularExpression) != nil }
        return trimmed + (isTrailerBlock ? "\n" : "\n\n") + fresh.joined(separator: "\n")
    }
}
