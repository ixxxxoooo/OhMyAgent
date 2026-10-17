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
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !trimmed.isEmpty, !trimmed.contains(coAuthorLine) else { return trimmed }
        // 已有尾注块(最后一段全是 `Key: value`)则紧接着写,否则空一行
        let lastBlock = trimmed.components(separatedBy: "\n\n").last ?? ""
        let isTrailerBlock = trimmed.contains("\n\n") && !lastBlock.isEmpty
            && lastBlock.split(separator: "\n").allSatisfy { $0.range(of: #"^[A-Za-z-]+: .+"#, options: .regularExpression) != nil }
        return trimmed + (isTrailerBlock ? "\n" : "\n\n") + coAuthorLine
    }
}
