// @author ixxxxoooo
// 上下文压缩:把 CLI 的压缩状态映射成一张「Compact conversation」工具卡(无 `session.compaction` 能力的客户端)。

import ACPKit
import Foundation

extension ClaudeSession {
    static let compactionTitle = "Compact conversation"

    /// 由 `compact_metadata` 生成压缩事实。
    static func compactionFacts(_ metadata: JSONValue?) -> [String: JSONValue] {
        guard let metadata else { return [:] }
        var facts: [String: JSONValue] = ["trigger": .string(metadata["trigger"]?.stringValue == "auto" ? "automatic" : "manual")]
        if let pre = metadata["pre_tokens"] { facts["preTokens"] = pre }
        if let post = metadata["post_tokens"] { facts["postTokens"] = post }
        if let duration = metadata["duration_ms"] { facts["durationMs"] = duration }
        return facts
    }

    /// 压缩开始:出一张进行中的工具卡。
    func compactionStarted(id: String?) async {
        if compactionId != nil, compactionTerminal == nil { return }
        let identifier = id ?? "compact-\(UUID().uuidString.prefix(8).lowercased())"
        compactionId = identifier
        compactionTerminal = nil
        compactionHeartbeat = false
        compactionDeliveredOutput = true
        await send(["sessionUpdate": "tool_call", "toolCallId": .string(identifier), "title": .string(Self.compactionTitle), "kind": "think", "status": "in_progress",
                    "_meta": ["claudeCode": ["toolName": "compact"]]])
    }

    /// 压缩结束(成功或失败)。可重复调用:边界消息会补充事实。
    func compactionFinished(id: String?, success: Bool, facts: [String: JSONValue]) async {
        let status = success ? "completed" : "failed"
        let opened = compactionId == nil
        let firstTerminal = compactionTerminal == nil
        let identifier = compactionId ?? id ?? "compact-\(UUID().uuidString.prefix(8).lowercased())"
        if opened { compactionId = identifier; compactionDeliveredOutput = true }
        if firstTerminal { compactionTerminal = status } else if facts.isEmpty { return }
        var update: [String: JSONValue] = ["toolCallId": .string(identifier), "_meta": ["claudeCode": ["toolName": "compact"]]]
        if opened || firstTerminal { update["status"] = .string(compactionTerminal ?? status) }
        if status == "failed", let error = facts["error"]?.stringValue {
            update["content"] = [["type": "content", "content": ["type": "text", "text": .string("Compaction failed: \(error)")]]]
        }
        if !facts.isEmpty { update["rawOutput"] = .object(facts) }
        if opened {
            update["sessionUpdate"] = "tool_call"
            update["title"] = .string(Self.compactionTitle)
            update["kind"] = "think"
            update["status"] = .string(status)
        } else {
            update["sessionUpdate"] = "tool_call_update"
        }
        await send(.object(update))
    }

    /// 回合结束时清理压缩状态。
    func resetCompaction() {
        compactionId = nil
        compactionTerminal = nil
        compactionDeliveredOutput = false
        compactionHeartbeat = false
    }
}
