// @author ixxxxoooo
// 子代理类型 → 图标:时间线卡片、任务坞、子代理标签页共用,让不同类型的子代理一眼可分。

import Foundation

/// 子代理图标映射(纯逻辑)。
public enum SubagentIcon {
    /// 按子代理类型挑选 Lucide 图标名;未知类型回退到通用机器人图标。
    /// - Parameter agentType: `subagent_type`(如 Explore、code-reviewer、general-purpose),可为空
    /// - Returns: 图标名
    public static func symbol(for agentType: String?) -> String {
        let type = (agentType ?? "").lowercased()
        guard !type.isEmpty else { return "bot" }
        let table: [(keys: [String], icon: String)] = [
            (["explore", "research", "search"], "file-search"),
            (["review", "audit", "security"], "shield-check"),
            (["plan", "architect"], "workflow"),
            (["doc", "guide", "write"], "book-open"),
            (["web", "browser"], "globe"),
            (["test", "debug", "fix"], "wrench"),
        ]
        return table.first { entry in entry.keys.contains { type.contains($0) } }?.icon ?? "bot"
    }
}
