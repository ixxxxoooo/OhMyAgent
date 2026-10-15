// @author ygw
// 时间线模型:把 ACP 的 session/update 流归并为可渲染的条目。
// 每个条目是独立的 @Observable 对象,流式追加文本时只会让对应条目的视图刷新。

import ACPKit
import Foundation
import Observation

/// 时间线条目。
@MainActor
@Observable
public final class TimelineEntry: Identifiable {
    /// 条目类别。
    public enum Kind: Sendable {
        case user, assistant, thought, tool, plan, notice
    }

    public nonisolated let id = UUID()
    public let kind: Kind
    /// 文本内容(用户、助手、思维、提示)
    public var text: String
    /// 工具调用(`kind == .tool`)
    public var tool: ToolCall?
    /// 计划条目(`kind == .plan`)
    public var plan: [PlanEntry] = []
    /// 是否仍在流式接收
    public var isStreaming: Bool
    /// 提示是否为错误(`kind == .notice`)
    public var isError = false
    public let startedAt = Date()
    public var finishedAt: Date?
    /// 协议消息 ID,用于把分片归并到同一条消息
    public var messageId: String?

    /// 创建条目。
    /// - Parameters:
    ///   - kind: 类别
    ///   - text: 初始文本
    ///   - isStreaming: 是否流式中
    public init(kind: Kind, text: String = "", isStreaming: Bool = false) {
        self.kind = kind
        self.text = text
        self.isStreaming = isStreaming
    }

    /// 思考耗时(秒)。
    public var elapsedSeconds: Double {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

/// 时间线存储。仅在主 actor 使用;更新来自合并后的批次,频率不高于约 80 次/秒。
@MainActor
@Observable
public final class TimelineStore {
    public private(set) var entries: [TimelineEntry] = []
    /// 每次变更自增,视图据此决定是否滚动到底部。
    public private(set) var revision = 0

    private var toolIndex: [String: TimelineEntry] = [:]
    private var planEntry: TimelineEntry?

    public init() {}

    /// 清空时间线。
    public func reset() {
        entries.removeAll()
        toolIndex.removeAll()
        planEntry = nil
        revision += 1
    }

    /// 追加用户消息(本地发送)。
    /// - Parameter text: 用户输入
    public func appendUser(_ text: String) {
        finishStreaming()
        planEntry = nil
        entries.append(TimelineEntry(kind: .user, text: text))
        revision += 1
    }

    /// 追加提示或错误。
    /// - Parameters:
    ///   - text: 文本
    ///   - isError: 是否错误
    public func appendNotice(_ text: String, isError: Bool = false) {
        finishStreaming()
        let entry = TimelineEntry(kind: .notice, text: text)
        entry.isError = isError
        entries.append(entry)
        revision += 1
    }

    /// 结束当前流式条目(轮次结束或切换类型时调用)。
    public func finishStreaming() {
        guard let last = entries.last, last.isStreaming else { return }
        last.isStreaming = false
        last.finishedAt = Date()
    }

    /// 应用一个会话更新;与时间线无关的更新会被忽略。
    /// - Parameter update: 协议更新
    public func apply(_ update: SessionUpdate) {
        switch update {
        case .userMessageChunk(let messageId, let content):
            appendChunk(kind: .user, messageId: messageId, content: content)
        case .agentMessageChunk(let messageId, let content):
            appendChunk(kind: .assistant, messageId: messageId, content: content)
        case .agentThoughtChunk(let messageId, let content):
            appendChunk(kind: .thought, messageId: messageId, content: content)
        case .toolCall(let call):
            finishStreaming()
            if let existing = toolIndex[call.toolCallId] {
                existing.tool = call
            } else {
                let entry = TimelineEntry(kind: .tool, isStreaming: false)
                entry.tool = call
                toolIndex[call.toolCallId] = entry
                entries.append(entry)
            }
        case .toolCallUpdate(let toolCallId, let raw):
            if let existing = toolIndex[toolCallId], var call = existing.tool {
                call.apply(update: raw)
                existing.tool = call
                if call.status.isTerminal, existing.finishedAt == nil { existing.finishedAt = Date() }
            } else {
                finishStreaming()
                let entry = TimelineEntry(kind: .tool)
                entry.tool = ToolCall(json: raw)
                toolIndex[toolCallId] = entry
                entries.append(entry)
            }
        case .plan(let items):
            if let planEntry {
                planEntry.plan = items
            } else {
                finishStreaming()
                let entry = TimelineEntry(kind: .plan)
                entry.plan = items
                planEntry = entry
                entries.append(entry)
            }
        default:
            return
        }
        revision += 1
    }

    /// 文本分片归并:同类、仍在流式、消息 ID 兼容时追加,否则新建条目。
    private func appendChunk(kind: TimelineEntry.Kind, messageId: String?, content: ContentBlock) {
        let text: String
        switch content {
        case .text(let value): text = value
        case .resourceLink(_, let name, _, let title): text = "[\(title ?? name)]"
        case .image: text = "[图片]"
        case .audio: text = "[音频]"
        default: return
        }
        if let last = entries.last, last.kind == kind, last.isStreaming,
           messageId == nil || last.messageId == nil || last.messageId == messageId {
            last.text += text
            if last.messageId == nil { last.messageId = messageId }
            return
        }
        finishStreaming()
        let entry = TimelineEntry(kind: kind, text: text, isStreaming: true)
        entry.messageId = messageId
        entries.append(entry)
    }
}
