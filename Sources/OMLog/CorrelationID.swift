// @author ixxxxoooo
// 关联标识规范:统一会话 / 回合 / 请求 / 工具调用在日志里的字段名与格式,
// 保证 `grep sid=xxxx` 能把一次回合的全链路日志串起来。

import Foundation

/// 关联标识的字段名与格式化。
public enum CorrelationID {
    /// 日志字段名。
    public enum Key {
        public static let session = "sid"
        public static let turn = "turn"
        public static let request = "req"
        public static let toolCall = "tcid"
    }

    /// 会话标识缩写长度。
    public static let sessionPrefixLength = 8

    /// 会话 id 缩写(前 8 位);空串返回 `-`。
    /// - Parameter id: 完整会话 id
    public static func session(_ id: String) -> String {
        id.isEmpty ? "-" : String(id.prefix(sessionPrefixLength))
    }

    /// 回合标识,如 `t12`。
    /// - Parameter sequence: 该会话内从 1 递增的回合序号
    public static func turn(_ sequence: Int) -> String {
        "t\(max(sequence, 0))"
    }
}

public extension OMLogger {
    /// 派生带统一关联标识的日志器;只写入非 nil 的项。
    /// - Parameters:
    ///   - session: 完整会话 id(自动缩写)
    ///   - turn: 回合序号
    ///   - request: 请求 id(ACP 或网关)
    ///   - toolCall: 工具调用 id
    /// - Returns: 带固定上下文的日志器
    func correlated(session: String? = nil, turn: Int? = nil, request: String? = nil, toolCall: String? = nil) -> OMLogger {
        var fields: [String: String] = [:]
        if let session { fields[CorrelationID.Key.session] = CorrelationID.session(session) }
        if let turn { fields[CorrelationID.Key.turn] = CorrelationID.turn(turn) }
        if let request { fields[CorrelationID.Key.request] = request }
        if let toolCall { fields[CorrelationID.Key.toolCall] = toolCall }
        return with(fields)
    }
}
