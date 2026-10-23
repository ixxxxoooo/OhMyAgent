// @author ixxxxoooo
// 上下文分类明细:转发 CLI 控制请求 `get_context_usage`。
// 与发送 `/context` 不同,控制请求不写转录、不进对话历史,刷新明细不会让后续每个请求多读一份命令输出。

import ACPKit
import Foundation

extension ClaudeSession {
    /// 读取上下文分类明细(`_session/context_usage`)。
    ///
    /// 只保留客户端需要的字段(分类、总量、窗口、模型),丢掉 CLI 为终端准备的 `gridRows` 等大字段。
    /// - Returns: `{categories:[{name,tokens,kind}], totalTokens, maxTokens, model?}`
    /// - Throws: 会话未就绪或 CLI 不支持该控制请求时抛错
    func contextUsage() async throws -> JSONValue {
        guard let query else { throw JSONRPCError(code: JSONRPCError.internalError, message: "会话未就绪") }
        let response = try await query.control("get_context_usage")
        return Self.trimContextUsage(response)
    }

    /// 裁剪 `get_context_usage` 的响应。
    /// - Parameter response: CLI 原始响应
    /// - Returns: 裁剪后的对象
    static func trimContextUsage(_ response: JSONValue) -> JSONValue {
        let categories: [JSONValue] = (response["categories"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue, let tokens = entry["tokens"]?.intValue else { return nil }
            return ["name": .string(name), "tokens": .int(tokens), "kind": .string(entry["kind"]?.stringValue ?? "used")]
        }
        var result: [String: JSONValue] = [
            "categories": .array(categories),
            "totalTokens": .int(response["totalTokens"]?.intValue ?? 0),
            "maxTokens": .int(response["maxTokens"]?.intValue ?? 0),
        ]
        if let model = response["model"]?.stringValue { result["model"] = .string(model) }
        return .object(result)
    }
}
