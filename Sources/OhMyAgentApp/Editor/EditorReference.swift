// @author ixxxxoooo
// 「在对话中引用选区」:把编辑器选区转换为 `@相对路径:起始行-结束行` 并追加到输入框草稿。

import EditorKit
import Foundation

/// 选区引用的纯函数工具。
enum EditorReference {
    /// 生成引用标记。
    /// - Parameters:
    ///   - path: 文件绝对路径
    ///   - projectRoot: 项目根目录(文件在其内时使用相对路径)
    ///   - text: 当前文本
    ///   - range: 选区(UTF-16)
    /// - Returns: 如 `@Sources/A.swift:12-20`;单行为 `@Sources/A.swift:12`
    static func token(path: String, projectRoot: String, text: String, range: NSRange) -> String {
        let index = LineIndex(text: text)
        let start = index.line(containing: range.location) + 1
        // 选区以换行结尾时,不把下一行算进去
        let lastOffset = max(range.location, NSMaxRange(range) - 1)
        let end = max(index.line(containing: lastOffset) + 1, start)
        let display = path.hasPrefix(projectRoot + "/") ? String(path.dropFirst(projectRoot.count + 1)) : path
        return end > start ? "@\(display):\(start)-\(end)" : "@\(display):\(start)"
    }

    /// 把引用追加到草稿末尾,与已有内容之间补一个空格,并以空格结尾方便继续输入。
    /// - Parameters:
    ///   - draft: 当前草稿
    ///   - token: 引用标记
    static func appending(_ token: String, to draft: String) -> String {
        if draft.isEmpty { return token + " " }
        let separator = draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
        return draft + separator + token + " "
    }
}
