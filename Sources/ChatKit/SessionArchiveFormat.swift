// @author ixxxxoooo
// 会话存档的文件格式:一会话一文件的 JSONL,参照 Claude Code 自身的转录(`~/.claude/projects/*/<id>.jsonl`)。
// 首行头信息;正文每行一条完整的 `session/update`(流式片段在内存合并后才落盘);元数据追加写、后写者胜。

import ACPKit
import CryptoKit
import Foundation

/// 存档键:同一会话 ID 在不同引擎下互不相干。
public struct SessionArchiveKey: Hashable, Sendable {
    /// 引擎(Agent 描述符)ID
    public var agentId: String
    /// 协议会话 ID
    public var sessionId: String

    /// 创建存档键。
    /// - Parameters:
    ///   - agentId: 引擎 ID
    ///   - sessionId: 协议会话 ID
    public init(agentId: String, sessionId: String) {
        self.agentId = agentId
        self.sessionId = sessionId
    }
}

/// 存档元数据(头信息 + 最新一条元数据行)。
public struct SessionArchiveMeta: Sendable, Equatable {
    /// 会话工作目录
    public var cwd: String?
    /// 存档创建时间
    public var createdAt: Date?
    /// 最近一次与引擎对齐(回合结束或全量同步完成)的时间
    public var syncedAt: Date?

    /// 创建元数据。
    public init(cwd: String? = nil, createdAt: Date? = nil, syncedAt: Date? = nil) {
        self.cwd = cwd
        self.createdAt = createdAt
        self.syncedAt = syncedAt
    }
}

/// 读出的存档:元数据与按序的原始更新。
public struct ArchivedSession: Sendable {
    /// 元数据
    public var meta: SessionArchiveMeta
    /// 原始 `session/update` 载荷(按写入顺序)
    public var updates: [JSONValue]
}

/// 全量同步的结果。
public enum SessionArchiveSyncOutcome: Sendable, Equatable {
    /// 原先没有存档,已新建
    case created
    /// 内容与现有存档一致,只刷新了同步时间
    case unchanged
    /// 内容有变化,已原子替换
    case replaced
    /// 引擎没有返回任何内容,未建档
    case empty
    /// 同步失败或被放弃,现有存档保持不变
    case failed
}

/// 格式编解码(纯函数,便于测试)。
enum SessionArchiveFormat {
    /// 当前格式版本;读到不同版本的存档视为不存在(派生数据,丢弃后可重新拉取)
    static let schema = 1

    /// 不落盘的更新类型:瞬时状态,打开会话时由引擎重新下发。
    static let transientKinds: Set<String> = ["available_commands_update", "config_option_update", "config_options_update"]

    /// 会让存档文件被创建的内容类更新(只有元数据的空会话不建档)。
    static let contentKinds: Set<String> = ["user_message_chunk", "agent_message_chunk", "agent_thought_chunk", "tool_call", "plan"]

    /// 可在内存合并的流式文本片段类型。
    static let chunkKinds: Set<String> = ["user_message_chunk", "agent_message_chunk", "agent_thought_chunk"]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    /// 编码一行(不含换行);编码失败返回 nil。
    static func line(_ value: JSONValue) -> Data? {
        guard var data = try? encoder.encode(value) else { return nil }
        data.append(0x0A)
        return data
    }

    /// 头信息行。
    static func header(_ key: SessionArchiveKey, cwd: String?, createdAt: Date) -> JSONValue {
        var object: [String: JSONValue] = ["t": "h", "schema": .int(schema), "agentId": .string(key.agentId),
                                           "sessionId": .string(key.sessionId), "createdAt": .string(iso(createdAt))]
        if let cwd { object["cwd"] = .string(cwd) }
        return .object(object)
    }

    /// 更新行。
    static func update(_ update: JSONValue) -> JSONValue { ["t": "u", "u": update] }

    /// 元数据行。
    static func meta(syncedAt: Date) -> JSONValue { ["t": "m", "syncedAt": .string(iso(syncedAt))] }

    /// 解析整份存档;版本不符、没有头信息时返回 nil。坏行与截断的末行直接跳过(与 Claude Code 读转录一致)。
    /// - Parameter data: 文件内容
    /// - Returns: 存档;没有任何更新时 `updates` 为空
    static func parse(_ data: Data) -> ArchivedSession? {
        let decoder = JSONDecoder()
        var meta = SessionArchiveMeta()
        var updates: [JSONValue] = []
        var sawHeader = false
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(JSONValue.self, from: Data(slice)) else { continue }
            switch record["t"]?.stringValue {
            case "h":
                guard record["schema"]?.intValue == schema else { return nil }
                sawHeader = true
                meta.cwd = record["cwd"]?.stringValue
                meta.createdAt = date(record["createdAt"]?.stringValue)
            case "u":
                if let update = record["u"] { updates.append(update) }
            case "m":
                if let synced = date(record["syncedAt"]?.stringValue) { meta.syncedAt = synced }
            default:
                continue
            }
        }
        return sawHeader ? ArchivedSession(meta: meta, updates: updates) : nil
    }

    /// 文件名安全的会话/引擎标识:字母数字与 `-_.` 原样保留,否则取 SHA256(防路径穿越、防过长)。
    static func safeName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if !raw.isEmpty, raw.count <= 128, !raw.hasPrefix("."), raw.unicodeScalars.allSatisfy(allowed.contains) { return raw }
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 存档是否落后于引擎:引擎侧更新时间晚于上次同步时间 + 容差(说明在别处续写过)。
    /// - Parameters:
    ///   - sourceUpdatedAt: 引擎列表给出的更新时间;未知时不判为陈旧
    ///   - syncedAt: 存档的同步时间;从未同步视为陈旧
    ///   - tolerance: 容差秒数(本应用自己的回合与引擎落盘时间相近)
    static func isStale(sourceUpdatedAt: Date?, syncedAt: Date?, tolerance: TimeInterval = 5) -> Bool {
        guard let syncedAt else { return true }
        guard let sourceUpdatedAt else { return false }
        return sourceUpdatedAt > syncedAt.addingTimeInterval(tolerance)
    }

    /// 带毫秒的 ISO8601 文本。
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// 解析 ISO8601(带或不带毫秒)。
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
