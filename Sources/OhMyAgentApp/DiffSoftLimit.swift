// @author ixxxxoooo
// 差异视图的软上限:超大差异默认只渲染前若干行,避免一次性建出几千行视图卡住主线程。

import DiffKit

/// 差异渲染的行数软上限。
enum DiffSoftLimit {
    /// 单次最多渲染的行数,超出需手动展开
    static let lines = 300

    /// 按行数预算截取要渲染的块;单个块超过预算时只保留其前若干行(块头计数不变)。
    /// - Parameters:
    ///   - hunks: 全部差异块
    ///   - total: 全部行数
    ///   - showAll: 用户是否已选择显示全部
    /// - Returns: 实际渲染的块(行数合计不超过 `lines`,至少保留一行)
    static func visible(_ hunks: [DiffHunk], total: Int, showAll: Bool) -> [DiffHunk] {
        guard total > lines, !showAll else { return hunks }
        var budget = lines
        var result: [DiffHunk] = []
        for hunk in hunks where budget > 0 {
            var shown = hunk
            if shown.lines.count > budget { shown.lines = Array(shown.lines.prefix(budget)) }
            budget -= shown.lines.count
            result.append(shown)
        }
        return result
    }

    /// 单行最多显示的字符数:超长行(压缩数据、生成代码)整行排版代价很高,只显示开头。
    static let maxLineChars = 1_000

    /// 截断超长行的显示文本。
    /// - Parameter text: 原始行文本
    /// - Returns: 不超过 `maxLineChars` 的文本;被截断时末尾追加省略说明
    static func displayText(_ text: String) -> String {
        guard text.utf16.count > maxLineChars else { return text }
        let head = text.prefix(maxLineChars)
        return head + String(localized: "… (已截断 \(text.count - head.count) 个字符)")
    }
}
