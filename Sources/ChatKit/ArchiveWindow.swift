// @author ixxxxoooo
// 存档回显窗口:打开长会话时只把「最近 N 轮」喂给时间线,更早的轮次折叠成「显示更早的 N 轮对话」,点击时再完整回显。
// 回显成本(解码 → 逐条应用 → 渲染)因此不再随会话总长度线性增长。纯逻辑,便于测试。

import ACPKit
import Foundation

/// 存档窗口切分结果。
struct ArchiveWindowCut: Equatable {
    /// 回显从第几条更新开始(之前的更新被折叠)
    let start: Int
    /// 被折叠的轮数
    let hiddenTurns: Int
    /// 窗口内保留的轮数
    let keptTurns: Int
}

/// 存档回显窗口计算。
enum ArchiveWindow {
    /// 折叠的最少轮数:被折叠的轮数低于它时不值得折叠,直接完整回显
    static let minimumHiddenTurns = 8

    /// 各「轮开头」在更新序列里的下标:用户消息块,且前一条不是用户消息块(同一条用户消息可能拆成多个块)。
    /// - Parameter updates: 存档里按序保存的更新
    /// - Returns: 轮开头下标(升序)
    static func turnStarts(_ updates: [JSONValue]) -> [Int] {
        var starts: [Int] = []
        var previousWasUser = false
        for (index, update) in updates.enumerated() {
            let isUser = update["sessionUpdate"]?.stringValue == "user_message_chunk"
            if isUser, !previousWasUser { starts.append(index) }
            previousWasUser = isUser
        }
        return starts
    }

    /// 计算回显窗口。
    /// - Parameters:
    ///   - updates: 存档里按序保存的更新
    ///   - keepTurns: 保留最近的轮数(至少 1);nil 表示完整回显
    /// - Returns: 切分结果;不需要折叠(轮数不够多或要求完整回显)时 `start == 0`、`hiddenTurns == 0`
    static func cut(_ updates: [JSONValue], keepTurns: Int?) -> ArchiveWindowCut {
        let starts = turnStarts(updates)
        guard let keepTurns else { return ArchiveWindowCut(start: 0, hiddenTurns: 0, keptTurns: starts.count) }
        let keep = max(keepTurns, 1)
        let hidden = starts.count - keep
        guard hidden >= minimumHiddenTurns else { return ArchiveWindowCut(start: 0, hiddenTurns: 0, keptTurns: starts.count) }
        return ArchiveWindowCut(start: starts[hidden], hiddenTurns: hidden, keptTurns: keep)
    }
}
