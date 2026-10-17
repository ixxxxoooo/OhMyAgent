// @author ixxxxoooo
// 从 Claude Code 会话记录(`.jsonl`)里还原每个回合的起止时间与模型,
// 让回放出来的历史回合(含终端里跑的)也能显示「耗时 · 完成于」结束行。

import Foundation

/// 会话记录里的一个回合。
public struct TranscriptTurn: Sendable, Equatable {
    /// 用户提问的时间
    public var start: Date
    /// 回合最后一条记录的时间(即完成时间)
    public var end: Date
    /// 回合内最后一条助手消息的模型(可能为空)
    public var model: String

    public init(start: Date, end: Date, model: String) {
        self.start = start
        self.end = end
        self.model = model
    }
}

/// 会话记录解析器(无状态)。
public enum TranscriptTurns {
    /// 解析记录文件,按时间顺序返回回合。
    /// - Parameter url: `.jsonl` 文件
    /// - Returns: 回合列表;文件不可读时为空
    public static func parse(_ url: URL) -> [TranscriptTurn] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return parse(data)
    }

    /// 解析记录数据。
    /// - Parameter data: `.jsonl` 内容
    /// - Returns: 回合列表
    public static func parse(_ data: Data) -> [TranscriptTurn] {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var turns: [TranscriptTurn] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // 只解码用户/助手行,跳过体量最大的附件与请求快照行
            guard line.range(of: Data(#""type":"user""#.utf8)) != nil || line.range(of: Data(#""type":"assistant""#.utf8)) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = object["type"] as? String, object["isSidechain"] as? Bool != true,
                  let stamp = object["timestamp"] as? String, let time = parser.date(from: stamp) else { continue }
            let message = object["message"] as? [String: Any]
            if type == "user" {
                if isPrompt(object, message: message) {
                    turns.append(TranscriptTurn(start: time, end: time, model: ""))
                } else if !turns.isEmpty, object["isMeta"] as? Bool != true {
                    // 元信息行(系统提醒等)不代表回合还在进行,不延长完成时间
                    turns[turns.count - 1].end = max(turns[turns.count - 1].end, time)
                }
            } else if !turns.isEmpty {
                turns[turns.count - 1].end = max(turns[turns.count - 1].end, time)
                if let model = message?["model"] as? String, !model.isEmpty, model != "<synthetic>" { turns[turns.count - 1].model = model }
            }
        }
        return turns
    }

    /// 是否是用户真正输入的提问(排除工具结果、元信息与本地命令输出)。
    private static func isPrompt(_ object: [String: Any], message: [String: Any]?) -> Bool {
        if object["isMeta"] as? Bool == true || object["sourceToolAssistantUUID"] != nil || object["toolUseResult"] != nil { return false }
        guard let content = message?["content"] else { return false }
        if let text = content as? String {
            return !text.hasPrefix("<local-command") && !text.hasPrefix("<command-name>") && !text.hasPrefix("<system-reminder>")
        }
        if let blocks = content as? [[String: Any]] {
            return !blocks.contains { $0["type"] as? String == "tool_result" }
        }
        return false
    }
}
