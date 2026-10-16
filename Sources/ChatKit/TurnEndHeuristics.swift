// @author ixxxxoooo
// 回合结束启发式:第三方适配器(如 pi-acp)在压缩失败、工具中断等情况下,会把错误当成正常结束上报(stopReason=end_turn),
// 表现为「回合无征兆地停在工具调用/思考之后」。这里用纯逻辑判断这种可疑结束,以便给出可操作的提示。

import Foundation
import ACPKit

/// 回合结束启发式判断(纯逻辑,便于测试)。
public enum TurnEndHeuristics {
    /// 判断一次「正常结束」的回合是否疑似被提前打断。
    /// - Parameters:
    ///   - isClaude: 当前是否是 Claude Code(其结束语义可靠,不做判断)
    ///   - reason: 回合停止原因,仅 `.endTurn` 才可能是「被当作正常结束的中断」
    ///   - lastKind: 本回合时间线中最后一个「实质性」条目的类别(忽略提示、结束语、改动汇总),无条目为 nil
    /// - Returns: 疑似被提前打断时为 true
    public static func looksTruncated(isClaude: Bool, reason: StopReason?, lastKind: TimelineEntry.Kind?) -> Bool {
        guard !isClaude, reason == .endTurn, let lastKind else { return false }
        // 正常的回合以助手文字收尾;停在工具调用或思考之后说明模型还没把话说完
        return lastKind == .tool || lastKind == .thought
    }

    /// 取时间线里最后一个实质性条目的类别。
    @MainActor
    public static func lastSubstantiveKind(in entries: [TimelineEntry]) -> TimelineEntry.Kind? {
        entries.last { ![.notice, .turnSummary, .changes].contains($0.kind) }?.kind
    }
}
