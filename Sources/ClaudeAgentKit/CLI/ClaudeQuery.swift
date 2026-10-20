// @author ixxxxoooo
// `claude` stream-json 控制通道:一个会话对应一个子进程,负责消息分发、控制请求的关联与反向请求(权限、钩子、征询)的应答。

import ACPKit
import Foundation
import OMLog

/// 控制通道的反向请求委托:`claude` 在运行中向宿主发起的请求由它回答。
public protocol ClaudeQueryDelegate: Sendable {
    /// 工具权限请求(`can_use_tool`)。
    /// - Parameters:
    ///   - request: 控制请求体(含 `tool_name`/`input`/`permission_suggestions`/`tool_use_id` 等)
    ///   - requestId: 控制请求 ID
    /// - Returns: 响应体(`{behavior: allow|deny, ...}`);返回 nil 表示保持静默(由 CLI 自行超时)
    func canUseTool(_ request: JSONValue, requestId: String) async -> JSONValue?
    /// 钩子回调(`hook_callback`)。
    /// - Parameters:
    ///   - callbackId: 初始化时登记的回调 ID
    ///   - input: 钩子输入
    ///   - toolUseId: 关联的工具调用 ID
    /// - Returns: 钩子输出,默认 `{continue: true}`
    func hookCallback(callbackId: String, input: JSONValue, toolUseId: String?) async -> JSONValue
    /// MCP 征询(`elicitation`)。
    /// - Returns: `{action: accept|decline|cancel, content?}`;nil 表示静默
    func elicitation(_ request: JSONValue) async -> JSONValue?
    /// 用户对话框请求(`request_user_dialog`)。
    /// - Returns: 响应体;nil 表示静默
    func userDialog(_ request: JSONValue) async -> JSONValue?
}

/// `claude` 控制通道出错。
public enum ClaudeQueryError: Error, LocalizedError, Sendable {
    /// 控制请求被 CLI 拒绝
    case controlFailed(String)
    /// 进程已退出或通道已关闭
    case closed(String)

    public var errorDescription: String? {
        switch self {
        case .controlFailed(let message): return message
        case .closed(let message): return message
        }
    }
}

/// 一个 `claude` 子进程的 stream-json 控制通道。
public actor ClaudeQuery {
    private let transport: any ACPTransport
    private let delegate: any ClaudeQueryDelegate
    private let log: OMLogger
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var inflight: [String: Task<Void, Never>] = [:]
    private var nextId = 1
    private var closed = false
    private var stderrTail = ""
    private var readTask: Task<Void, Never>?

    /// 非控制消息流(`stream_event`/`assistant`/`user`/`system`/`result` 等),按到达顺序投递。
    public nonisolated let messages: AsyncStream<JSONValue>
    private let messageContinuation: AsyncStream<JSONValue>.Continuation
    /// 进程退出事件(带最近的 stderr 尾部),仅投递一次。
    public nonisolated let exits: AsyncStream<String>
    private let exitContinuation: AsyncStream<String>.Continuation

    /// 创建控制通道。
    /// - Parameters:
    ///   - transport: 与 `claude` 子进程相连的传输(生产为 `StdioTransport`,测试为内存传输)
    ///   - delegate: 反向请求委托
    ///   - label: 日志标识(会话 ID)
    public init(transport: any ACPTransport, delegate: any ClaudeQueryDelegate, label: String = "") {
        self.transport = transport
        self.delegate = delegate
        self.log = label.isEmpty ? Log.agent : Log.agent.with(["query": label])
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
        self.messages = stream
        self.messageContinuation = continuation
        let (exitStream, exitCont) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        self.exits = exitStream
        self.exitContinuation = exitCont
    }

    /// 启动传输并开始读取。
    public func start() throws {
        let events = try transport.start()
        readTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    /// 最近的 stderr 文本(用于错误提示)。
    public var recentStderr: String { stderrTail }

    // MARK: 发送

    /// 向 CLI 发送一条用户消息。
    /// - Parameters:
    ///   - content: 内容块(Anthropic 消息格式)
    ///   - uuid: 消息 UUID(用于回放确认与回合匹配)
    ///   - priority: 排队优先级(`now` 为转向,即时注入)
    public func sendUser(content: [JSONValue], uuid: String, priority: String? = nil) {
        let message = JSONValue.make([
            ("type", "user"),
            ("message", ["role": "user", "content": .array(content)]),
            ("parent_tool_use_id", .null),
            ("session_id", ""),
            ("uuid", .string(uuid)),
            ("priority", priority.map(JSONValue.string)),
        ])
        write(message)
    }

    /// 发起控制请求并等待响应。
    /// - Parameters:
    ///   - subtype: 控制请求子类型(如 `initialize`、`interrupt`、`set_model`)
    ///   - fields: 附加字段
    /// - Returns: 响应体(`response` 字段)
    /// - Throws: `ClaudeQueryError`
    @discardableResult
    public func control(_ subtype: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        if closed { throw ClaudeQueryError.closed(Self.closedMessage(stderrTail)) }
        let id = "req_\(nextId)_\(UUID().uuidString.prefix(8).lowercased())"
        nextId += 1
        var request = fields
        request["subtype"] = .string(subtype)
        let message: JSONValue = ["type": "control_request", "request_id": .string(id), "request": .object(request)]
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(message)
        }
    }

    /// 关闭通道并终止子进程。
    public func close() {
        guard !closed else { return }
        transport.stop()
        finish(reason: "已关闭")
    }

    // MARK: 内部

    private func write(_ value: JSONValue) {
        guard let data = value.serialized() else { return }
        transport.send(data)
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .line(let data):
            guard let value = JSONValue.parse(data) else {
                log.warning("无法解析 CLI 输出行", ["bytes": "\(data.count)", "head": String(decoding: data.prefix(160), as: UTF8.self)])
                return
            }
            dispatch(value)
        case .stderr(let text):
            stderrTail = String((stderrTail + text).suffix(4000))
        case .closed(let code):
            finish(reason: "claude 进程已退出(\(code.map { "\($0)" } ?? "-"))")
        }
    }

    private func dispatch(_ value: JSONValue) {
        switch value["type"]?.stringValue {
        case "control_response":
            guard let response = value["response"], let id = response["request_id"]?.stringValue else { return }
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if response["subtype"]?.stringValue == "error" {
                continuation.resume(throwing: ClaudeQueryError.controlFailed(response["error"]?.stringValue ?? "控制请求失败"))
            } else {
                continuation.resume(returning: response["response"] ?? .object([:]))
            }
        case "control_request":
            handleControlRequest(value)
        case "control_cancel_request":
            if let id = value["request_id"]?.stringValue { inflight.removeValue(forKey: id)?.cancel() }
        case "keep_alive", "transcript_mirror":
            break
        default:
            messageContinuation.yield(value)
        }
    }

    /// 处理 CLI 发来的控制请求:异步调用委托,完成后写回 `control_response`。
    private func handleControlRequest(_ value: JSONValue) {
        guard let id = value["request_id"]?.stringValue, let request = value["request"] else { return }
        if inflight[id] != nil { return }
        let subtype = request["subtype"]?.stringValue ?? ""
        let delegate = self.delegate
        inflight[id] = Task { [weak self] in
            let outcome: Result<JSONValue?, Error>
            switch subtype {
            case "can_use_tool":
                var response = await delegate.canUseTool(request, requestId: id)
                if var object = response?.objectValue, let toolUseId = request["tool_use_id"] {
                    object["toolUseID"] = toolUseId
                    response = .object(object)
                }
                outcome = .success(response)
            case "hook_callback":
                let result = await delegate.hookCallback(
                    callbackId: request["callback_id"]?.stringValue ?? "",
                    input: request["input"] ?? .null,
                    toolUseId: request["tool_use_id"]?.stringValue
                )
                outcome = .success(result)
            case "elicitation":
                outcome = .success(await delegate.elicitation(request))
            case "request_user_dialog":
                outcome = .success(await delegate.userDialog(request))
            default:
                outcome = .failure(ClaudeQueryError.controlFailed("不支持的控制请求:\(subtype)"))
            }
            if Task.isCancelled { return }
            await self?.reply(id: id, outcome: outcome)
        }
    }

    private func reply(id: String, outcome: Result<JSONValue?, Error>) {
        inflight.removeValue(forKey: id)
        if closed { return }
        switch outcome {
        case .success(let response?):
            write(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id), "response": response]])
        case .success(nil):
            break
        case .failure(let error):
            write(["type": "control_response", "response": ["subtype": "error", "request_id": .string(id), "error": .string(error.localizedDescription)]])
        }
    }

    private func finish(reason: String) {
        guard !closed else { return }
        closed = true
        let error = ClaudeQueryError.closed(Self.closedMessage(stderrTail, reason: reason))
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
        messageContinuation.finish()
        exitContinuation.yield(Self.closedMessage(stderrTail, reason: reason))
        exitContinuation.finish()
        readTask?.cancel()
        log.info("控制通道关闭", ["reason": reason])
    }

    private static func closedMessage(_ stderr: String, reason: String = "claude 进程已退出") -> String {
        let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? reason : "\(reason):\(String(tail.suffix(600)))"
    }
}
