// @author ixxxxoooo
// 测试用假 `claude`:通过内存传输说 stream-json 协议,脚本化回放控制响应与消息流,不依赖真实模型或网络。

import ACPKit
import Foundation
@testable import ClaudeAgentKit

/// 假 `claude` 进程。测试通过 `transport` 把宿主侧接到它,再用 `emit`/`onUser` 编排行为。
final class FakeClaudeCLI: @unchecked Sendable {
    /// 交给被测代码的传输(宿主侧)
    let transport: LoopbackTransport
    private let cliSide: LoopbackTransport
    private let lock = NSLock()
    private var userHandler: (@Sendable (JSONValue) -> Void)?
    private var controlHandler: (@Sendable (String, JSONValue, String) -> JSONValue?)?
    private var receivedLines: [JSONValue] = []
    private var task: Task<Void, Never>?

    init() {
        let (host, cli) = LoopbackTransport.makePair()
        self.transport = host
        self.cliSide = cli
    }

    /// 开始读取宿主发来的数据。
    func start() throws {
        let stream = try cliSide.start()
        task = Task { [weak self] in
            for await event in stream {
                guard case .line(let data) = event, let value = JSONValue.parse(data) else { continue }
                self?.receive(value)
            }
        }
    }

    /// 注册用户消息回调。
    func onUser(_ handler: @escaping @Sendable (JSONValue) -> Void) {
        lock.withLock { userHandler = handler }
    }

    /// 注册控制请求回调:返回响应体(nil = 不回应)。
    func onControl(_ handler: @escaping @Sendable (_ subtype: String, _ request: JSONValue, _ requestId: String) -> JSONValue?) {
        lock.withLock { controlHandler = handler }
    }

    /// 宿主发来的全部行(拷贝)。
    var received: [JSONValue] { lock.withLock { receivedLines } }

    /// 向宿主发一条消息。
    func emit(_ value: JSONValue) {
        guard let data = value.serialized() else { return }
        cliSide.send(data)
    }

    /// 模拟 CLI 向宿主发起控制请求(如权限询问)。
    func request(_ subtype: String, id: String, _ fields: [String: JSONValue]) {
        var body = fields
        body["subtype"] = .string(subtype)
        emit(["type": "control_request", "request_id": .string(id), "request": .object(body)])
    }

    /// 关闭(模拟进程退出)。
    func exit() { cliSide.stop() }

    private func receive(_ value: JSONValue) {
        let (user, control) = lock.withLock { () -> ((@Sendable (JSONValue) -> Void)?, (@Sendable (String, JSONValue, String) -> JSONValue?)?) in
            receivedLines.append(value)
            return (userHandler, controlHandler)
        }
        switch value["type"]?.stringValue {
        case "user":
            user?(value)
        case "control_request":
            let id = value["request_id"]?.stringValue ?? ""
            let request = value["request"] ?? .null
            let subtype = request["subtype"]?.stringValue ?? ""
            let response = control.map { $0(subtype, request, id) } ?? Self.defaultResponse(subtype)
            if let response {
                emit(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id), "response": response]])
            }
        default:
            break
        }
    }

    /// 缺省的控制响应:`initialize` 给出一个最小可用结果,其余返回空对象。
    static func defaultResponse(_ subtype: String) -> JSONValue? {
        if subtype == "initialize" { return Self.initializeResult() }
        return .object([:])
    }

    /// 与真实 CLI 形状一致的 `initialize` 响应(模型与命令清单精简)。
    static func initializeResult() -> JSONValue {
        [
            "commands": [
                ["name": "compact", "description": "压缩上下文", "argumentHint": "", "builtin": true],
                ["name": "review", "description": "代码评审", "argumentHint": ""],
            ],
            "agents": [["name": "general-purpose", "description": "通用"]],
            "models": [
                ["value": "default", "displayName": "Default (recommended)", "description": "Opus 4.7", "supportsEffort": true,
                 "supportedEffortLevels": ["low", "medium", "high"], "supportsAutoMode": true, "resolvedModel": "claude-opus-4-7"],
                ["value": "sonnet", "displayName": "Sonnet", "description": "Sonnet 4.6", "supportsEffort": true,
                 "supportedEffortLevels": ["low", "medium", "high"], "resolvedModel": "claude-sonnet-4-6"],
                ["value": "haiku", "displayName": "Haiku", "description": "Haiku 4.5"],
            ],
            "account": ["email": "tester@example.com"],
        ]
    }

    /// 构造一条 `result` 消息。
    static func result(
        subtype: String = "success", isError: Bool = false, text: String = "ok",
        stopReason: String? = "end_turn", uuids: [String] = [], extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var body: [String: JSONValue] = [
            "type": "result", "subtype": .string(subtype), "is_error": .bool(isError), "result": .string(text),
            "num_turns": 1, "total_cost_usd": 0.01, "session_id": "s",
            "usage": ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 2, "cache_creation_input_tokens": 1],
            "modelUsage": ["claude-opus-4-7": ["inputTokens": 10, "outputTokens": 5, "cacheReadInputTokens": 2,
                                                "cacheCreationInputTokens": 1, "contextWindow": 200_000]],
        ]
        if let stopReason { body["stop_reason"] = .string(stopReason) }
        if !uuids.isEmpty { body["user_message_uuids"] = .array(uuids.map(JSONValue.string)) }
        for (key, value) in extra { body[key] = value }
        return .object(body)
    }
}
