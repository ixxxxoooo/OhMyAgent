// @author ixxxxoooo
// 工具分组「最新一步」行的数据判定(纯逻辑,便于测试):展示哪一步、是否处于工具间空窗。

import Foundation

extension ExploreGroup {
    /// 最新一步要展示的工具条目:优先取最后一个仍在运行的工具(并行调用时先结束的不抢位),
    /// 没有运行中的工具时取最后一个工具。
    /// - Returns: 工具条目;分组内没有工具时为 nil
    public var tickerEntry: TimelineEntry? {
        let tools = entries.filter { $0.kind == .tool && $0.tool != nil }
        return tools.last { !($0.tool?.status.isTerminal ?? true) } ?? tools.last
    }

    /// 是否处于工具之间的空窗:没有任何运行中的工具(含分组内尚无工具、只有思考的情况)。
    public var isBetweenSteps: Bool {
        guard let tool = tickerEntry?.tool else { return true }
        return tool.status.isTerminal
    }
}
