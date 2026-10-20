// @author ixxxxoooo
// 会话转录存储:读取 `~/.claude/projects/<目录>/<会话>.jsonl`,提供列表、历史链、尾部元数据、重命名与删除。
// 只读本机 `claude` 自己写的转录文件,不读取任何凭据。

import ACPKit
import Foundation
import OMLog

/// 会话列表项(对应 SDK 的 `SDKSessionInfo`)。
public struct TranscriptInfo: Sendable, Equatable {
    public var sessionId: String
    public var cwd: String?
    /// 展示标题:自定义标题 > AI 标题 > 最近提示 > 摘要 > 首条提示
    public var summary: String
    public var customTitle: String?
    public var lastModified: Date
    public var path: String
}

/// 转录尾部提取到的恢复信息。
public struct TranscriptTail: Sendable, Equatable {
    public var model: String?
    public var permissionMode: String?
}

/// 会话转录读写。
public struct TranscriptStore: Sendable {
    /// Claude 配置根目录(`CLAUDE_CONFIG_DIR` 或 `~/.claude`)
    public let configDirectory: URL
    private let log = Log.agent.with(["part": "transcript"])

    /// 创建存储。
    /// - Parameter configDirectory: 配置根目录;默认读环境变量与用户主目录
    public init(configDirectory: URL? = nil) {
        if let configDirectory {
            self.configDirectory = configDirectory
        } else if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            self.configDirectory = URL(fileURLWithPath: env)
        } else {
            self.configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
    }

    var projectsDirectory: URL { configDirectory.appendingPathComponent("projects") }

    /// 工作目录对应的项目目录名(非字母数字字符替换为 `-`,与 `claude` 一致)。
    /// - Parameter cwd: 工作目录绝对路径
    public static func projectDirectoryName(for cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar in
            (scalar.value < 128 && (CharacterSet.alphanumerics.contains(scalar))) ? Character(scalar) : "-"
        })
    }

    /// 校验会话 ID(UUID 形态),防止路径穿越。
    public static func isValidSessionId(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    // MARK: 查找

    /// 在所有项目目录里查找会话转录文件。
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - cwd: 优先查找的工作目录
    public func findTranscript(_ sessionId: String, cwd: String? = nil) -> URL? {
        guard Self.isValidSessionId(sessionId) else { return nil }
        let manager = FileManager.default
        if let cwd {
            let candidate = projectsDirectory.appendingPathComponent(Self.projectDirectoryName(for: cwd)).appendingPathComponent("\(sessionId).jsonl")
            if manager.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let directories = try? manager.contentsOfDirectory(atPath: projectsDirectory.path) else { return nil }
        for directory in directories {
            let candidate = projectsDirectory.appendingPathComponent(directory).appendingPathComponent("\(sessionId).jsonl")
            if manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: 列表与信息

    /// 列出会话(按修改时间倒序)。
    /// - Parameters:
    ///   - cwd: 只列该工作目录的会话;nil 列出全部
    ///   - limit: 最多返回条数
    ///   - offset: 跳过条数
    public func list(cwd: String?, limit: Int, offset: Int) -> [TranscriptInfo] {
        let manager = FileManager.default
        var directories: [URL] = []
        if let cwd {
            directories = [projectsDirectory.appendingPathComponent(Self.projectDirectoryName(for: cwd))]
        } else if let names = try? manager.contentsOfDirectory(atPath: projectsDirectory.path) {
            directories = names.map { projectsDirectory.appendingPathComponent($0) }
        }
        var files: [(url: URL, modified: Date)] = []
        for directory in directories {
            guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for url in urls where url.pathExtension == "jsonl" && Self.isValidSessionId(url.deletingPathExtension().lastPathComponent) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((url, modified))
            }
        }
        files.sort { $0.modified > $1.modified }
        var result: [TranscriptInfo] = []
        var skipped = 0
        for file in files {
            guard let info = Self.readInfo(url: file.url, modified: file.modified, fallbackCwd: cwd) else { continue }
            if skipped < offset { skipped += 1; continue }
            result.append(info)
            if result.count >= limit { break }
        }
        return result
    }

    /// 读取单个会话的信息。
    public func info(sessionId: String, cwd: String? = nil) -> TranscriptInfo? {
        guard let url = findTranscript(sessionId, cwd: cwd) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return Self.readInfo(url: url, modified: modified, fallbackCwd: cwd)
    }

    /// 从文件头尾各 64KB 提取标题与首条提示。
    static func readInfo(url: URL, modified: Date, fallbackCwd: String?) -> TranscriptInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 64 * 1024
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: Int(min(size, chunk)))) ?? Data()
        var tail = head
        if size > chunk {
            try? handle.seek(toOffset: size - chunk)
            tail = (try? handle.read(upToCount: Int(chunk))) ?? Data()
        }
        let headLines = lines(of: head, dropFirst: false, dropLast: size > chunk)
        let tailLines = lines(of: tail, dropFirst: size > chunk, dropLast: false)
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
        var summary: String?
        for line in tailLines {
            if line.contains("\"custom-title\""), let value = JSONValue.parse(line), value["type"]?.stringValue == "custom-title" {
                customTitle = value["customTitle"]?.nonEmptyString ?? customTitle
            } else if line.contains("\"ai-title\""), let value = JSONValue.parse(line), value["type"]?.stringValue == "ai-title" {
                aiTitle = value["aiTitle"]?.nonEmptyString ?? aiTitle
            } else if line.contains("\"last-prompt\""), let value = JSONValue.parse(line), value["type"]?.stringValue == "last-prompt" {
                lastPrompt = value["lastPrompt"]?.nonEmptyString ?? lastPrompt
            } else if line.contains("\"summary\""), let value = JSONValue.parse(line), value["type"]?.stringValue == "summary" {
                summary = value["summary"]?.nonEmptyString ?? summary
            }
        }
        // 头部也可能含自定义标题(分叉会话把标题写在末尾,故以尾部为准)
        var firstPrompt: String?
        var cwd: String?
        for line in headLines {
            guard let value = JSONValue.parse(line) else { continue }
            if cwd == nil { cwd = value["cwd"]?.nonEmptyString }
            if firstPrompt == nil, value["type"]?.stringValue == "user", value["isMeta"]?.boolValue != true, value["isSidechain"]?.boolValue != true {
                firstPrompt = promptText(value["message"]?["content"])
            }
            if cwd != nil, firstPrompt != nil { break }
        }
        let title = customTitle ?? aiTitle ?? lastPrompt ?? summary ?? firstPrompt
        guard let title, !title.isEmpty else { return nil }
        return TranscriptInfo(
            sessionId: url.deletingPathExtension().lastPathComponent, cwd: cwd ?? fallbackCwd,
            summary: title, customTitle: customTitle, lastModified: modified, path: url.path
        )
    }

    private static func promptText(_ content: JSONValue?) -> String? {
        if let text = content?.stringValue { return stripMarkers(text).nonEmptyTrimmed }
        for block in content?.arrayValue ?? [] where block["type"]?.stringValue == "text" {
            if let text = block["text"]?.stringValue, let clean = stripMarkers(text).nonEmptyTrimmed { return clean }
        }
        return nil
    }

    private static func stripMarkers(_ text: String) -> String {
        ReplayText.stripMarkerTags(text)
    }

    private static func lines(of data: Data, dropFirst: Bool, dropLast: Bool) -> [String] {
        var parts = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if dropFirst, !parts.isEmpty { parts.removeFirst() }
        if dropLast, !parts.isEmpty { parts.removeLast() }
        return parts
    }

    // MARK: 历史链

    /// 读取会话主线消息(沿 `parentUuid` 从最新叶子回溯,按时间正序),只含 user/assistant,不含 isMeta。
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - cwd: 优先查找目录
    /// - Returns: SDK 形态的消息(`type/uuid/session_id/message/parent_tool_use_id`),找不到文件时为空
    public func messages(sessionId: String, cwd: String? = nil) -> [JSONValue] {
        guard let url = findTranscript(sessionId, cwd: cwd), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var entries: [String: JSONValue] = [:]
        var order: [String] = []
        var leaf: String?
        for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard Self.isChainCandidate(lineData), let value = JSONValue.parse(Data(lineData)) else { continue }
            guard let type = value["type"]?.stringValue, type == "user" || type == "assistant" || type == "system",
                  let uuid = value["uuid"]?.nonEmptyString else { continue }
            if entries[uuid] == nil { order.append(uuid) }
            entries[uuid] = value
            if type != "system", value["isSidechain"]?.boolValue != true { leaf = uuid }
        }
        var chain: [JSONValue] = []
        var cursor = leaf
        var seen = Set<String>()
        while let id = cursor, let entry = entries[id], seen.insert(id).inserted {
            chain.append(entry)
            cursor = entry["parentUuid"]?.nonEmptyString
        }
        chain.reverse()
        return chain.compactMap { Self.sdkMessage($0, sessionId: sessionId) }
    }

    private static func isChainCandidate(_ line: Data.SubSequence) -> Bool {
        guard line.count > 12 else { return false }
        // 大量 api-request 等元数据行不含这三种 type,先用字节扫描跳过
        for marker in ["\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"system\""] {
            if line.range(of: Data(marker.utf8)) != nil { return true }
        }
        return false
    }

    /// 转录条目 → SDK 消息形态。
    private static func sdkMessage(_ entry: JSONValue, sessionId: String) -> JSONValue? {
        guard let type = entry["type"]?.stringValue, type == "user" || type == "assistant", entry["message"] != nil else { return nil }
        if entry["isMeta"]?.boolValue == true { return nil }
        return JSONValue.make([
            ("type", .string(type)), ("uuid", entry["uuid"]), ("session_id", .string(sessionId)), ("message", entry["message"]),
            ("parent_tool_use_id", entry["parent_tool_use_id"] ?? .null),
            ("tool_use_result", entry["toolUseResult"]), ("origin", entry["origin"]),
            ("isCompactSummary", entry["isCompactSummary"]),
        ])
    }

    /// 最后一条真实 assistant 消息使用的具体模型名(合成消息 `<synthetic>` 忽略)。
    public static func resumedModel(from messages: [JSONValue]) -> String? {
        for message in messages.reversed() where message["type"]?.stringValue == "assistant" && (message["parent_tool_use_id"]?.isNull ?? true) {
            if let model = concreteModel(message.at("message", "model")?.stringValue) { return model }
        }
        return nil
    }

    static func concreteModel(_ model: String?) -> String? {
        guard let name = model?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if name.hasPrefix("<"), name.hasSuffix(">") { return nil }
        return name
    }

    // MARK: 尾部元数据

    /// 从转录尾部提取恢复所需的模型与权限模式(从文件末尾向前读,成本与会话长度无关)。
    public func tail(sessionId: String, cwd: String? = nil, withModel: Bool = true) -> TranscriptTail {
        guard let url = findTranscript(sessionId, cwd: cwd), let handle = try? FileHandle(forReadingFrom: url) else { return TranscriptTail() }
        defer { try? handle.close() }
        var result = TranscriptTail()
        var modeDone = false
        var planExited = false
        var end = (try? handle.seekToEnd()) ?? 0
        var carry = Data()
        let chunkSize: UInt64 = 64 * 1024
        func visit(_ line: Data) -> Bool {
            let text = String(decoding: line, as: UTF8.self)
            func record(_ marker: String) -> JSONValue? {
                guard text.contains(marker), let value = JSONValue.parse(line), value["isSidechain"]?.boolValue != true else { return nil }
                return value
            }
            if withModel, result.model == nil, let entry = record("\"assistant\""), entry["type"]?.stringValue == "assistant" {
                result.model = Self.concreteModel(entry.at("message", "model")?.stringValue)
            }
            if !modeDone {
                if let entry = record("\"permissionMode\""), entry["type"]?.stringValue == "user",
                   let mode = entry["permissionMode"]?.stringValue?.trimmingCharacters(in: .whitespaces), !mode.isEmpty {
                    modeDone = true
                    if !(planExited && mode == "plan") { result.permissionMode = mode }
                } else if let entry = record("\"plan_mode_exit\""), entry.at("attachment", "type")?.stringValue == "plan_mode_exit" {
                    planExited = true
                } else if let entry = record("\"human\""), entry["type"]?.stringValue == "user", entry.at("origin", "kind")?.stringValue == "human" {
                    modeDone = true
                }
            }
            return (!withModel || result.model != nil) && modeDone
        }
        while end > 0 {
            let start = end > chunkSize ? end - chunkSize : 0
            try? handle.seek(toOffset: start)
            var chunk = (try? handle.read(upToCount: Int(end - start))) ?? Data()
            chunk.append(carry)
            end = start
            var parts = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
            // 首段可能是被截断的半行,留到下一轮拼接
            carry = start > 0 ? Data(parts.removeFirst()) : Data()
            for part in parts.reversed() where !part.isEmpty {
                if visit(Data(part)) { return result }
            }
        }
        if !carry.isEmpty { _ = visit(carry) }
        return result
    }

    // MARK: 重命名 / 删除 / 目录

    /// 追加自定义标题记录(与 SDK `renameSession` 一致)。
    /// - Throws: 会话不存在或写入失败
    public func rename(sessionId: String, title: String, cwd: String? = nil) throws {
        guard let url = findTranscript(sessionId, cwd: cwd) else { throw TranscriptError.notFound(sessionId) }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptError.invalid("标题不能为空") }
        let entry: JSONValue = ["type": "custom-title", "customTitle": .string(trimmed), "sessionId": .string(sessionId)]
        guard var line = entry.serialized() else { return }
        line.append(0x0A)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size > 0 {
            // 文件末尾没有换行时先补一个,避免新记录黏在上一行后面
            try handle.seek(toOffset: size - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }

    /// 删除会话转录及其子目录(子 Agent 转录等)。
    /// - Throws: 会话不存在
    public func delete(sessionId: String, cwd: String? = nil) throws {
        guard let url = findTranscript(sessionId, cwd: cwd) else { throw TranscriptError.notFound(sessionId) }
        try FileManager.default.removeItem(at: url)
        let sidecar = url.deletingPathExtension()
        if FileManager.default.fileExists(atPath: sidecar.path) { try? FileManager.default.removeItem(at: sidecar) }
        log.info("会话转录已删除", ["session": String(sessionId.prefix(8))])
    }
}

/// 转录存储错误。
public enum TranscriptError: Error, LocalizedError, Sendable {
    case notFound(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "会话不存在:\(id)"
        case .invalid(let message): return message
        }
    }
}

extension String {
    /// 去首尾空白后非空则返回,否则 nil。
    var nonEmptyTrimmed: String? {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
