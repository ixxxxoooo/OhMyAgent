// @author ixxxxoooo
// Agent 终端:适配器自己执行的 Bash(含后台命令)经 `_meta.terminal_*` 报告,
// 这里把它们镜像成 `TerminalSession`(外部终端),供工具卡、任务坞与只读终端标签页展示。

import ACPKit
import Foundation
import OMLog

extension SessionModel {
    /// 处理会话更新里的终端事件(含子 Agent 内部的更新)。
    /// - Parameter update: 协议更新
    func observeTerminalMeta(_ update: SessionUpdate) {
        switch update {
        case .toolCall(let call):
            if let event = call.terminalEvent { applyTerminalEvent(event, rawInput: call.rawInput) }
        case .toolCallUpdate(_, let raw):
            if let event = ToolTerminalEvent.parse(raw["_meta"]) { applyTerminalEvent(event, rawInput: raw["rawInput"]) }
        case .childUpdate(_, let inner):
            observeTerminalMeta(inner)
        default:
            break
        }
    }

    /// 应用一条终端事件:创建会话、写入输出、跟读后台输出文件、标记结束。
    private func applyTerminalEvent(_ event: ToolTerminalEvent, rawInput: JSONValue?) {
        let session: TerminalSession
        if let existing = terminals[event.terminalId] {
            session = existing
        } else {
            session = TerminalSession(id: event.terminalId, command: rawInput?["command"]?.stringValue ?? "", isExternal: true)
            terminals[event.terminalId] = session
            Log.session.info("Agent 终端已登记", ["terminalId": event.terminalId])
        }
        if let command = rawInput?["command"]?.stringValue { session.updateCommand(command) }
        if rawInput?["run_in_background"]?.boolValue == true { session.declaredBackground = true }
        if let text = event.output {
            if event.outputIsDelta {
                session.appendExternal(text)
            } else if let path = ToolTerminalEvent.backgroundOutputPath(in: text) {
                // 后台命令:结果文字只是「已转入后台」的提示,真正的输出在文件里,跟读它
                session.followFile(path)
                Log.session.info("Agent 后台命令跟读输出文件", ["terminalId": event.terminalId])
            } else {
                session.replaceExternal(text)
            }
        }
        if event.finished { session.finishExternal(exitCode: event.exitCode, signal: event.signal) }
    }

    /// 工具状态变化时同步外部终端:补全命令文本;前台命令工具已结束而终端未收尾(例如被拒绝、被中断)时兜底收尾。
    /// 后台命令的工具会在转入后台时就标为完成,此时命令仍在运行,不能收尾。
    /// - Parameter call: 合并后的工具调用
    func syncExternalTerminal(for call: ToolCall) {
        guard let session = terminals[call.toolCallId], session.isExternal else { return }
        if let command = call.rawInput?["command"]?.stringValue { session.updateCommand(command) }
        if call.rawInput?["run_in_background"]?.boolValue == true { session.declaredBackground = true }
        if call.status.isTerminal, session.isRunning, !session.isBackground {
            session.finishExternal(exitCode: nil, signal: nil)
        }
    }
}
