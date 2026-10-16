// @author ixxxxoooo
// 输入栏上方的「任务坞」:排队消息 / 后台子 Agent / 运行中的终端三类,以胶囊标签切换面板(参考 Cursor)。
// 纯逻辑(无视图):决定当前展示哪一类面板。

import Foundation

/// 任务坞的分区。
public enum ComposerDockSection: String, CaseIterable, Sendable, Hashable {
    case queued
    case subagents
    case terminals

    /// 计算当前实际展示的面板。
    /// - Parameters:
    ///   - selection: 用户上次选中的分区
    ///   - hidden: 用户是否主动收起了面板(只剩胶囊)
    ///   - counts: 各分区当前条数
    /// - Returns: 要展示的分区;全部为空或已收起时返回 nil
    public static func effective(selection: ComposerDockSection?, hidden: Bool, counts: [ComposerDockSection: Int]) -> ComposerDockSection? {
        guard !hidden else { return nil }
        if let selection, counts[selection, default: 0] > 0 { return selection }
        return allCases.first { counts[$0, default: 0] > 0 }
    }
}
