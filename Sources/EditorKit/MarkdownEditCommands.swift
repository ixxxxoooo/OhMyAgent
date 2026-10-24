// @author ixxxxoooo
// Markdown 源码编辑的基础交互(纯函数,便于测试):
// - 列表续行:在列表项末尾按回车自动续出下一项,空项回车结束列表。
// 所有范围均为 UTF-16 偏移。原先的任务框点击切换、链接 ⌘ 点击只服务已删除的就地渲染,一并移除。

import Foundation

/// 一次文本替换(替换范围 + 新文本 + 替换后光标位置)。
public struct MarkdownEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    /// 替换完成后的光标位置(UTF-16 偏移,相对替换后的整篇文本)
    public var caret: Int
}

/// Markdown 编辑命令。
public enum MarkdownEditCommands {
    /// 列表项行:缩进、引用前缀、标记(`-`/`*`/`+`/`1.`/`1)`)、可选任务框、正文。
    private static let listPattern = try? NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)*)([-*+]|\d{1,9}[.)])([ \t]+)(\[[ xX]\][ \t]+)?(.*)$"#)

    // MARK: 行工具

    /// 包含偏移的整行范围(不含行尾换行)。
    private static func lineRange(in text: NSString, at offset: Int) -> NSRange {
        let clamped = min(max(offset, 0), text.length)
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: clamped, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    // MARK: 列表续行

    /// 在光标处按回车时的列表续行。
    /// - Parameters:
    ///   - text: 整篇文本
    ///   - selection: 当前选区(必须是折叠的光标,且在行尾才续行)
    /// - Returns: 续行(或结束列表)的替换;不适用时返回 nil,由调用方走默认回车
    public static func continueList(in text: String, selection: NSRange) -> MarkdownEdit? {
        guard selection.length == 0, let listPattern else { return nil }
        let ns = text as NSString
        guard selection.location <= ns.length else { return nil }
        let line = lineRange(in: ns, at: selection.location)
        // 只在行尾回车才续行;行中间回车保持默认(把后半行带到下一行)
        guard selection.location == NSMaxRange(line), let match = listPattern.firstMatch(in: text, range: line) else { return nil }
        let prefix = ns.substring(with: match.range(at: 1))
        let marker = ns.substring(with: match.range(at: 2))
        let gap = ns.substring(with: match.range(at: 3))
        let hasTask = match.range(at: 4).location != NSNotFound
        let body = ns.substring(with: match.range(at: 5))
        // 空项回车:去掉标记,结束列表
        if body.trimmingCharacters(in: .whitespaces).isEmpty {
            let emptied = NSRange(location: line.location, length: line.length)
            return MarkdownEdit(range: emptied, replacement: "", caret: line.location)
        }
        let nextMarker = incremented(marker)
        let insertion = "\n" + prefix + nextMarker + gap + (hasTask ? "[ ] " : "")
        return MarkdownEdit(range: NSRange(location: selection.location, length: 0), replacement: insertion, caret: selection.location + (insertion as NSString).length)
    }

    /// 下一项的标记:有序列表数字加一,无序列表原样。
    private static func incremented(_ marker: String) -> String {
        guard let last = marker.last, last == "." || last == ")", let number = Int(marker.dropLast()) else { return marker }
        return "\(number + 1)\(last)"
    }
}
