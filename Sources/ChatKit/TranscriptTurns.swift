// @author ixxxxoooo
// 从 Claude Code 会话记录(`.jsonl`)里还原每个回合的起止时间与模型,
// 让回放出来的历史回合(含终端里跑的)也能显示「耗时 · 完成于」结束行。

import ACPKit
import Foundation
import OMLog

/// 会话记录里的一个回合。
public struct TranscriptTurn: Sendable, Equatable {
    /// 用户提问的时间
    public var start: Date
    /// 回合最后一条记录的时间(即完成时间)
    public var end: Date
    /// 回合内最后一条助手消息的模型(可能为空)
    public var model: String
    /// 回合内各次模型请求的 token 用量合计(记录里没有 usage 时为 nil)
    public var usage: TurnUsage?
    /// 回合内最后一次模型请求的上下文占用(输入 + 缓存读写 + 输出);用于重新打开会话后还原「上下文窗口」
    public var lastContextTokens: Int?

    public init(start: Date, end: Date, model: String, usage: TurnUsage? = nil, lastContextTokens: Int? = nil) {
        self.start = start
        self.end = end
        self.model = model
        self.usage = usage
    }
}

/// 会话记录解析器(无状态)。
public enum TranscriptTurns {
    /// 解析记录文件,按时间顺序返回回合。
    /// - Parameter url: `.jsonl` 文件
    /// - Returns: 回合列表;文件不可读时为空
    public static func parse(_ url: URL) -> [TranscriptTurn] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let span = Log.perf.span("会话记录解析", warnMs: 300, ["bytes": "\(data.count)"])
        let turns = parse(data)
        span.end(["turns": "\(turns.count)"])
        return turns
    }

    /// 解析记录数据。
    /// - Parameter data: `.jsonl` 内容
    /// - Returns: 回合列表
    public static func parse(_ data: Data) -> [TranscriptTurn] {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var turns: [TranscriptTurn] = []
        // 同一条助手消息会按内容块拆成多行并重复携带 usage:按消息 ID 去重,取最后一行(流式累计值)
        var perMessage: [[String: TurnUsage]] = []
        let userMarker = Data(#""type":"user""#.utf8), assistantMarker = Data(#""type":"assistant""#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // 只解码用户/助手行,跳过体量最大的附件与请求快照行
            guard line.range(of: userMarker) != nil || line.range(of: assistantMarker) != nil else { continue }
            // 快速路径:字节扫描顶层字段。工具结果回灌行(体量最大)只需要时间戳,不必整行解析成对象树
            if let fields = line.withUnsafeBytes({ TranscriptLineScanner.scan($0) }) {
                if fields.isSidechain { continue }
                if fields.type == "user", fields.hasToolMarker, let stamp = fields.timestamp, let time = parser.date(from: stamp) {
                    // 不是提问;元信息行不延长完成时间
                    if !turns.isEmpty, !fields.isMeta { turns[turns.count - 1].end = max(turns[turns.count - 1].end, time) }
                    continue
                }
            }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = object["type"] as? String, object["isSidechain"] as? Bool != true,
                  let stamp = object["timestamp"] as? String, let time = parser.date(from: stamp) else { continue }
            let message = object["message"] as? [String: Any]
            if type == "user" {
                if isPrompt(object, message: message) {
                    turns.append(TranscriptTurn(start: time, end: time, model: ""))
                    perMessage.append([:])
                } else if !turns.isEmpty, object["isMeta"] as? Bool != true {
                    // 元信息行(系统提醒等)不代表回合还在进行,不延长完成时间
                    turns[turns.count - 1].end = max(turns[turns.count - 1].end, time)
                }
            } else if !turns.isEmpty {
                turns[turns.count - 1].end = max(turns[turns.count - 1].end, time)
                if let model = message?["model"] as? String, !model.isEmpty, model != "<synthetic>" { turns[turns.count - 1].model = model }
                if let id = message?["id"] as? String, let usage = usage(from: message?["usage"] as? [String: Any]) {
                    perMessage[turns.count - 1][id] = usage
                    turns[turns.count - 1].lastContextTokens = usage.totalTokens
                }
            }
        }
        for index in turns.indices where !perMessage[index].isEmpty {
            let all = perMessage[index].values
            turns[index].usage = TurnUsage(inputTokens: all.reduce(0) { $0 + $1.inputTokens }, outputTokens: all.reduce(0) { $0 + $1.outputTokens },
                                           cachedReadTokens: all.reduce(0) { $0 + $1.cachedReadTokens }, cachedWriteTokens: all.reduce(0) { $0 + $1.cachedWriteTokens })
        }
        return turns
    }

    /// 把记录里的 `usage` 字典转成 `TurnUsage`;全为 0 或缺失时返回 nil。
    private static func usage(from node: [String: Any]?) -> TurnUsage? {
        guard let node else { return nil }
        func count(_ key: String) -> Int { (node[key] as? NSNumber)?.intValue ?? 0 }
        let value = TurnUsage(inputTokens: count("input_tokens"), outputTokens: count("output_tokens"),
                              cachedReadTokens: count("cache_read_input_tokens"), cachedWriteTokens: count("cache_creation_input_tokens"))
        return value.totalTokens > 0 ? value : nil
    }

    /// 是否是用户真正输入的提问(排除工具结果、元信息与本地命令输出)。
    private static func isPrompt(_ object: [String: Any], message: [String: Any]?) -> Bool {
        if object["isMeta"] as? Bool == true || object["sourceToolAssistantUUID"] != nil || object["toolUseResult"] != nil { return false }
        guard let content = message?["content"] else { return false }
        if let text = content as? String {
            return !text.hasPrefix("<local-command") && !text.hasPrefix("<command-name>") && !text.hasPrefix("<system-reminder>")
                && SyntheticUserMessage.classify(text) == nil
        }
        if let blocks = content as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return false }
            // 单个文本块是合成消息(如中断)时同样不算一次提问
            if blocks.count == 1, let text = blocks[0]["text"] as? String, SyntheticUserMessage.classify(text) != nil { return false }
            return true
        }
        return false
    }
}
