// @author ixxxxoooo
// 子代理卡片的实时状态(对标 Cursor 子代理):启动中 → 运行中 → 完成/失败,待办计数,当前在做什么。
// 纯逻辑:从子代理的工具条目与其内部时间线推导,无视图。

import ACPKit
import Foundation

/// 子代理的实时状态。
public struct SubagentStatus: Sendable, Equatable {
    /// 阶段。
    public enum Phase: Sendable, Equatable {
        /// 启动中:已派发,内部还没有任何产出
        case starting
        /// 运行中(前台)
        case running
        /// 在后台运行:父会话不等待它
        case backgroundRunning
        /// 已完成
        case completed
        /// 失败
        case failed
    }

    /// 当前活动的类别。
    public enum ActivityKind: Sendable, Equatable {
        case thinking, tool, message
    }

    public var phase: Phase
    /// 待办:已完成 / 总数(没有待办时都是 0)
    public var todoDone: Int
    public var todoTotal: Int
    /// 当前活动(仅运行中有):思考片段、正在执行的工具或最近一句话
    public var activityKind: ActivityKind?
    public var activityText: String?
    /// 内部工具调用次数
    public var toolUses: Int

    /// 是否仍在进行(启动中 / 运行中 / 后台运行)。
    public var isActive: Bool { [.starting, .running, .backgroundRunning].contains(phase) }

    /// 由子代理的父工具条目推导状态。
    /// - Parameter entry: 子代理的父工具条目
    /// - Returns: 状态;条目不是工具时返回 nil
    @MainActor
    public static func make(entry: TimelineEntry) -> SubagentStatus? {
        guard let tool = entry.tool else { return nil }
        let child = entry.childStore?.entries ?? []
        let background = tool.rawInput?["run_in_background"]?.boolValue == true || tool.asyncRunning
        let phase: Phase
        switch tool.status {
        case .completed where tool.asyncRunning: phase = .backgroundRunning
        case .completed: phase = .completed
        case .failed: phase = .failed
        case .pending, .inProgress:
            if background { phase = .backgroundRunning } else { phase = child.isEmpty ? .starting : .running }
        }
        let todos = latestTodos(in: child)
        var status = SubagentStatus(phase: phase, todoDone: todos.done, todoTotal: todos.total, activityKind: nil, activityText: nil,
                                    toolUses: child.filter { $0.kind == .tool }.count)
        if status.isActive, let activity = currentActivity(in: child) {
            status.activityKind = activity.kind
            status.activityText = activity.text
        }
        return status
    }

    /// 最近一次待办更新:TodoWrite 的入参或 plan 更新,以时间线里靠后的为准。
    @MainActor
    private static func latestTodos(in entries: [TimelineEntry]) -> (done: Int, total: Int) {
        for entry in entries.reversed() {
            if entry.kind == .plan, !entry.plan.isEmpty {
                return (entry.plan.filter { $0.status == "completed" }.count, entry.plan.count)
            }
            if entry.kind == .tool, entry.tool?.name == "TodoWrite", let todos = entry.tool?.rawInput?["todos"]?.arrayValue, !todos.isEmpty {
                return (todos.filter { $0["status"]?.stringValue == "completed" }.count, todos.count)
            }
        }
        return (0, 0)
    }

    /// 当前活动:取时间线末尾最近的思考 / 工具 / 文字。
    @MainActor
    private static func currentActivity(in entries: [TimelineEntry]) -> (kind: ActivityKind, text: String)? {
        for entry in entries.reversed() {
            switch entry.kind {
            case .thought:
                if let line = lastLine(entry.text) { return (.thinking, line) }
            case .assistant:
                if let line = lastLine(entry.text) { return (.message, line) }
            case .tool:
                if let tool = entry.tool, !tool.status.isTerminal || entry === entries.last { return (.tool, tool.title) }
            default:
                continue
            }
        }
        return nil
    }

    /// 取文本最后一个非空行并截断。
    /// 从尾部逐行向前找,只扫描末尾几行(流式长文本不再全文切分,避免 O(n²))。
    static func lastLine(_ text: String) -> String? {
        var end = text.endIndex
        while end > text.startIndex {
            let lineStart = text[text.startIndex..<end].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let line = text[lineStart..<end].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line.count > 80 ? String(line.prefix(80)) + "…" : line }
            guard lineStart > text.startIndex else { break }
            end = text.index(before: lineStart)
        }
        return nil
    }
}

extension TimelineStore {
    /// 顶层时间线里仍在运行的前台子代理数量:父会话在等它们(后台子代理不算)。
    public func runningForegroundSubagentCount() -> Int {
        entries.reduce(0) { total, entry in
            guard entry.kind == .tool, let tool = entry.tool, tool.isSubagentRunning else { return total }
            guard entry.childStore != nil || ToolPresentation.isSubagentLaunch(tool) else { return total }
            return tool.runsInBackground ? total : total + 1
        }
    }

    /// 任务坞展示的子代理:仍在运行的**后台**子代理(含嵌套);前台子代理由时间线上的卡片展示,不进任务坞。
    /// - Returns: 条目与嵌套深度
    public func runningBackgroundSubagents() -> [(entry: TimelineEntry, depth: Int)] {
        subagentEntries().filter { item in
            guard let tool = item.entry.tool, tool.isSubagentRunning else { return false }
            return tool.runsInBackground
        }
    }
}

extension ToolCall {
    /// 子 Agent 是否仍在运行:工具调用未终结,或异步启动后仍在后台跑。
    public var isSubagentRunning: Bool { !status.isTerminal || asyncRunning }

    /// 是否后台运行:入参声明 `run_in_background`,或适配器标记为异步启动。
    public var runsInBackground: Bool { rawInput?["run_in_background"]?.boolValue == true || asyncRunning }
}
