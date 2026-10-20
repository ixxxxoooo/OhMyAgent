// @author ixxxxoooo
// 工具调用字段追踪:记住客户端已持有的每个工具调用字段,`tool_call_update` 只携带变化的部分
// (Write 的整份文件内容重复发送会白白占用带宽)。

import ACPKit
import Foundation

/// 工具调用字段追踪器。
struct ToolCallFieldTracker {
    /// 客户端遇到即整体覆盖的字段
    private static let replacedFields = ["status", "title", "kind", "content", "locations", "rawInput", "rawOutput"]
    /// 客户端按键合并的 `_meta` 命名空间
    private static let mergedNamespaces: Set<String> = ["claudeCode", "jetbrains"]

    private struct Entry {
        var fields: [String: String] = [:]
        var mergedMeta: [String: String] = [:]
        var contentPinned = false
    }

    private var calls: [String: Entry] = [:]

    /// 记录 `tool_call`,或剔除 `tool_call_update` 里未变化的字段。
    /// - Parameters:
    ///   - update: 更新体(可被改写)
    ///   - replacePinnedContent: 终态结果是否允许覆盖已固定的审批补丁
    /// - Returns: 是否仍携带新信息;false 表示调用方应丢弃这条更新
    mutating func apply(_ update: inout JSONValue, replacePinnedContent: Bool = false) -> Bool {
        guard var object = update.objectValue, let kind = object["sessionUpdate"]?.stringValue,
              let id = object["toolCallId"]?.stringValue else { return true }
        if kind == "tool_call" {
            var entry = Entry()
            for field in Self.replacedFields { if let value = object[field] { entry.fields[field] = Self.canonical(value) } }
            _ = Self.record(&entry, meta: object["_meta"])
            calls[id] = entry
            return true
        }
        guard kind == "tool_call_update", var entry = calls[id] else { return true }
        var changed = false
        for field in Self.replacedFields {
            guard let value = object[field] else { continue }
            if field == "content", entry.contentPinned {
                if !replacePinnedContent {
                    object[field] = nil
                    continue
                }
                entry.contentPinned = false
            }
            let text = Self.canonical(value)
            if entry.fields[field] == text {
                object[field] = nil
                continue
            }
            entry.fields[field] = text
            changed = true
        }
        let meta = object["_meta"]
        if let keys = meta?.objectValue?.keys, keys.contains(where: { !Self.mergedNamespaces.contains($0) }) { changed = true }
        if Self.record(&entry, meta: meta) { changed = true }
        calls[id] = entry
        update = .object(object)
        return changed
    }

    /// 固定客户端展示的精确审批补丁:后续流式输入细化不得覆盖它,直到终态结果。
    mutating func pinContent(_ id: String, _ content: [JSONValue]) {
        guard var entry = calls[id] else { return }
        entry.fields["content"] = Self.canonical(.array(content))
        entry.contentPinned = true
        calls[id] = entry
    }

    /// 忘记一个工具调用。
    mutating func delete(_ id: String) { calls[id] = nil }

    /// 会话收尾时忘记全部。
    mutating func clear() { calls.removeAll() }

    private static func canonical(_ value: JSONValue) -> String { String(decoding: value.serialized() ?? Data(), as: UTF8.self) }

    /// 记录 `_meta.claudeCode.*` / `jetbrains.*` 的键值,返回是否有键变化。
    private static func record(_ entry: inout Entry, meta: JSONValue?) -> Bool {
        var changed = false
        func note(_ key: String, _ value: JSONValue) {
            let text = canonical(value)
            if entry.mergedMeta[key] == text { return }
            entry.mergedMeta[key] = text
            changed = true
        }
        for (key, value) in meta?["claudeCode"]?.objectValue ?? [:] { note("claudeCode.\(key)", value) }
        for (key, value) in meta?["jetbrains"]?.objectValue ?? [:] {
            if key == "air", let air = value.objectValue {
                for (inner, innerValue) in air { note("jetbrains.air.\(inner)", innerValue) }
            } else {
                note("jetbrains.\(key)", value)
            }
        }
        return changed
    }
}
