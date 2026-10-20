// @author ixxxxoooo
// JSON-RPC 2.0 消息模型与行分帧工具。

import Foundation

/// 请求标识,支持整数与字符串。
public enum RequestID: Sendable, Hashable, Codable, CustomStringConvertible {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "请求 id 必须为整数或字符串")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .int(let value): return String(value)
        case .string(let value): return value
        }
    }
}

/// JSON-RPC 错误对象。
public struct JSONRPCError: Error, LocalizedError, Sendable, Codable, Hashable {
    /// 面向用户的错误描述:直接使用 Agent 返回的 `message`
    /// (否则界面只会显示「ACPKit.JSONRPCError 错误 1」这种毫无信息量的文案)。
    /// 若 Agent 按 ACP 惯例把原因放在 `data.details`(内部错误的 message 只是 “Internal error”),一并展示。
    public var errorDescription: String? {
        if let details = data?["details"]?.stringValue, !details.isEmpty, !message.contains(details) { return "\(message): \(details)" }
        return message
    }

    /// 是否为「需要先认证」类错误:ACP 约定的 -32000,或消息明确表示未登录。
    public var isAuthRequired: Bool {
        if code == -32000 { return true }
        let text = message.lowercased()
        return ["authentication required", "not authenticated", "unauthenticated", "please log in", "please sign in", "login required"].contains { text.contains($0) }
    }

    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// 标准错误码。
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    /// ACP 约定:请求被取消。
    public static let requestCancelled = -32800
}

/// JSON-RPC 消息(请求、通知、成功响应、错误响应)。
public enum JSONRPCMessage: Sendable, Hashable {
    case request(id: RequestID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: RequestID, result: JSONValue)
    case errorResponse(id: RequestID?, error: JSONRPCError)

    /// 将一行 JSON 数据解析为消息。
    /// - Parameter data: 单条消息的 UTF-8 数据
    /// - Returns: 解析后的消息
    /// - Throws: 格式不合法时抛出 `JSONRPCError`
    public static func parse(_ data: Data) throws -> JSONRPCMessage {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw JSONRPCError(code: JSONRPCError.parseError, message: "JSON 解析失败: \(error.localizedDescription)")
        }
        guard case .object(let object) = value else {
            throw JSONRPCError(code: JSONRPCError.invalidRequest, message: "消息必须是 JSON 对象")
        }
        let id: RequestID? = try object["id"].flatMap { raw in
            raw.isNull ? nil : try raw.decode(RequestID.self)
        }
        if let method = object["method"]?.stringValue {
            let params = object["params"]
            if let id {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }
        if let errorValue = object["error"], !errorValue.isNull {
            let error = (try? errorValue.decode(JSONRPCError.self))
                ?? JSONRPCError(code: JSONRPCError.internalError, message: "未知错误")
            return .errorResponse(id: id, error: error)
        }
        if let id, let result = object["result"] {
            return .response(id: id, result: result)
        }
        if let id {
            // 部分实现省略 result 字段,视为 null
            return .response(id: id, result: .null)
        }
        throw JSONRPCError(code: JSONRPCError.invalidRequest, message: "无法识别的 JSON-RPC 消息")
    }

    /// 序列化为不含换行的 JSON 数据。
    /// - Returns: UTF-8 数据(不含结尾换行符)
    public func serialized() throws -> Data {
        var object: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch self {
        case .request(let id, let method, let params):
            object["id"] = try JSONValue.from(id)
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .notification(let method, let params):
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .response(let id, let result):
            object["id"] = try JSONValue.from(id)
            object["result"] = result
        case .errorResponse(let id, let error):
            object["id"] = try id.map { try JSONValue.from($0) } ?? .null
            object["error"] = try JSONValue.from(error)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(object))
    }
}

/// 换行分隔的行分帧器,处理被拆分到多次读取中的消息。
public struct LineFramer: Sendable {
    private var buffer = Data()
    /// 单行最大长度,超过则丢弃并上报,防止恶意或异常数据撑爆内存。
    public let maxLineLength: Int

    public init(maxLineLength: Int = 64 * 1024 * 1024) {
        self.maxLineLength = maxLineLength
    }

    /// 喂入新数据,返回其中完整的行。
    /// - Parameter chunk: 新读取到的数据
    /// - Returns: 完整行数组(不含换行符,忽略空行)
    public mutating func push(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        // 一次扫描切出所有完整行,最后只移除一次已消费前缀(避免逐行移除导致的平方复杂度)
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            var end = newline
            if end > lineStart, buffer[buffer.index(before: end)] == 0x0D { end = buffer.index(before: end) }
            if end > lineStart { lines.append(Data(buffer[lineStart..<end])) }
            lineStart = buffer.index(after: newline)
        }
        if lineStart > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<lineStart) }
        if buffer.count > maxLineLength {
            buffer.removeAll(keepingCapacity: false)
        }
        return lines
    }
}
