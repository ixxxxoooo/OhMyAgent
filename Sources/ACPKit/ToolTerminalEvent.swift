// @author ixxxxoooo
// 适配器经 `_meta` 报告的工具终端事件。客户端在 initialize 里声明 `_meta.terminal_output` 后,
// Claude Code 适配器会把 Bash 的命令输出放进 `terminal_info` / `terminal_output` / `terminal_exit`,
// 而不是塞进工具卡的文本内容。注意:输出只在命令结束时整段给出,不是实时流;
// 后台命令只有「开始」与任务结束时的 `terminal_exit`,实时输出在磁盘文件里(见 `backgroundOutputPath`)。

import Foundation

/// 一条工具终端事件(同一个更新里可同时带有开始、输出、结束)。
public struct ToolTerminalEvent: Sendable, Hashable {
    /// 终端标识(等于 Bash 工具调用的 toolCallId)
    public var terminalId: String
    /// 是否带有 `terminal_info`(终端开始)
    public var started = false
    /// 输出文本(`terminal_output.data`;增量模式见 `outputIsDelta`)
    public var output: String?
    /// 输出是否为增量(`terminal_output_delta`)
    public var outputIsDelta = false
    /// 是否带有 `terminal_exit`(命令结束)
    public var finished = false
    /// 退出码(信号终止或未知为 nil)
    public var exitCode: Int?
    /// 终止信号
    public var signal: String?

    public init(terminalId: String) { self.terminalId = terminalId }

    /// 从更新的 `_meta` 解析。
    /// - Parameter meta: `tool_call` / `tool_call_update` 的 `_meta`
    /// - Returns: 事件;没有任何终端字段或缺少终端标识时返回 nil
    public static func parse(_ meta: JSONValue?) -> ToolTerminalEvent? {
        let info = meta?["terminal_info"]
        let delta = meta?["terminal_output_delta"]
        let output = meta?["terminal_output"] ?? delta
        let exit = meta?["terminal_exit"]
        guard info != nil || output != nil || exit != nil else { return nil }
        let id = [info, output, exit].compactMap { $0?["terminal_id"]?.stringValue }.first { !$0.isEmpty }
        guard let id else { return nil }
        var event = ToolTerminalEvent(terminalId: id)
        event.started = info != nil
        if let output {
            event.output = output["data"]?.stringValue ?? ""
            event.outputIsDelta = meta?["terminal_output"] == nil && delta != nil
        }
        if let exit {
            event.finished = true
            event.exitCode = exit["exit_code"]?.intValue
            event.signal = exit["signal"]?.stringValue
        }
        return event
    }

    /// 从后台命令的结果文字里取出输出文件路径。
    /// Claude Code 的后台 Bash 结果形如「Command running in background with ID: bk1. Output is being written to: /tmp/…/tasks/bk1.output」。
    /// - Parameter text: 工具结果文字
    /// - Returns: 输出文件路径;不是后台命令的结果时返回 nil
    public static func backgroundOutputPath(in text: String) -> String? {
        let marker = "Output is being written to:"
        guard text.contains("running in background"), let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        // 路径通常以 .output 结尾;否则取到第一个空白为止,并去掉句末的句号
        if let end = rest.range(of: ".output") { return String(rest[..<end.upperBound]) }
        let token = rest.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let path = token.hasSuffix(".") ? String(token.dropLast()) : token
        return path.hasPrefix("/") ? path : nil
    }
}
