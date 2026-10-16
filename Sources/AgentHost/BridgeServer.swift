// @author ixxxxoooo
// OhMyAgent Bridge:本机回环网关上的 MCP 服务器(Streamable HTTP)。
// Agent 以 HTTP MCP 方式连接(无需垫片子进程),即可调用客户端能力:打开文件、显示 diff、读取选区、系统通知。

import ACPKit
import Foundation
import OMLog
import ProviderProxyKit
import Synchronization

/// 工具调用结果。
public struct BridgeResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// Bridge 工具的客户端实现(由会话模型提供)。
public protocol BridgeHandler: Sendable {
    func openFile(path: String, line: Int?) async -> BridgeResult
    func showDiff(path: String) async -> BridgeResult
    func selection() async -> BridgeResult
    func notify(title: String, message: String) async -> BridgeResult
}

/// Bridge 暴露的工具名(设置页可逐个开关)。
public enum BridgeTool: String, CaseIterable, Sendable, Codable {
    case openFile = "open_file"
    case showDiff = "show_diff"
    case getSelection = "get_selection"
    case notify = "notify"

    /// 工具说明(给模型看,英文更利于调用)。
    var summary: String {
        switch self {
        case .openFile: return "Open a file in the OhMyAgent editor panel, optionally at a line."
        case .showDiff: return "Show the pending changes of a file made in this session in the OhMyAgent diff viewer."
        case .getSelection: return "Get the text currently selected by the user in the OhMyAgent editor or conversation."
        case .notify: return "Show a macOS notification to the user (use sparingly, e.g. when a long task finishes)."
        }
    }

    var schema: JSONValue {
        func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string))]
        }
        switch self {
        case .openFile: return object(["path": ["type": "string"], "line": ["type": "integer"]], required: ["path"])
        case .showDiff: return object(["path": ["type": "string"]], required: ["path"])
        case .getSelection: return object([:], required: [])
        case .notify: return object(["title": ["type": "string"], "message": ["type": "string"]], required: ["message"])
        }
    }

    /// 在 MCP 中的完整展示名。
    public var displayName: String { "ohmyagent." + rawValue }
}

/// Bridge 服务器:通过本机网关暴露 MCP(Streamable HTTP,JSON 响应),每个会话一个不可猜测的令牌路径。
public final class BridgeServer: Sendable {
    private let handler: any BridgeHandler
    private let enabled: Set<BridgeTool>
    private let gateway: LocalGateway
    private let token = Mutex<String?>(nil)

    /// - Parameters:
    ///   - handler: 工具实现
    ///   - enabled: 启用的工具
    ///   - gateway: 本机网关(默认应用共享实例;测试可注入)
    public init(handler: any BridgeHandler, enabled: Set<BridgeTool> = Set(BridgeTool.allCases), gateway: LocalGateway = .shared) {
        self.handler = handler
        self.enabled = enabled
        self.gateway = gateway
    }

    /// 注册到网关并返回 MCP 地址。
    /// - Returns: 交给 Agent 的 HTTP MCP 地址
    /// - Throws: 网关启动失败
    public func start() async throws -> URL {
        let handler = handler, enabled = enabled
        let registered = try await gateway.register { request in
            await Self.serve(request, handler: handler, enabled: enabled)
        }
        token.withLock { $0 = registered.token }
        Log.bridge.info("Bridge 已注册到本机网关")
        return registered.url
    }

    /// 注销路由(会话结束时调用)。
    public func stop() {
        let previous = token.withLock { (current: inout String?) -> String? in
            let value = current
            current = nil
            return value
        }
        guard let value = previous else { return }
        let gateway = gateway
        Task { await gateway.unregister(token: value) }
        Log.bridge.info("Bridge 已注销")
    }

    /// 清理旧版本(Unix socket 垫片时代)遗留在临时目录里的 `oma-*.sock` 文件。
    public static func removeLegacySockets() {
        let directory = NSTemporaryDirectory()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasPrefix("oma-") && name.hasSuffix(".sock") {
            try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent(name))
        }
    }

    /// 处理一次 HTTP 请求:POST 一条 JSON-RPC;通知返回 202;其余方法返回 405。
    static func serve(_ request: HTTPRequest, handler: any BridgeHandler, enabled: Set<BridgeTool>) async -> HTTPResult {
        guard request.method.uppercased() == "POST" else {
            return .full(status: 405, headers: ["Allow": "POST"], body: Data())
        }
        guard let response = await respond(to: request.body, handler: handler, enabled: enabled) else {
            return .full(status: 202, headers: [:], body: Data())
        }
        return .full(status: 200, headers: ["Content-Type": "application/json"], body: response)
    }

    // MARK: - MCP 处理(静态,便于直接测试)

    /// 处理一行 JSON-RPC;通知返回 nil。
    static func respond(to line: Data, handler: any BridgeHandler, enabled: Set<BridgeTool>) async -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line), let method = message["method"]?.stringValue else { return nil }
        guard let id = message["id"] else { return nil }   // 通知无需响应
        let params = message["params"]
        func reply(_ result: JSONValue) -> Data? { try? JSONEncoder().encode(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result])) }
        func fail(_ code: Int, _ text: String) -> Data? {
            try? JSONEncoder().encode(JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(text)]]))
        }
        switch method {
        case "initialize":
            let version = params?["protocolVersion"]?.stringValue ?? "2025-06-18"
            return reply(["protocolVersion": .string(version), "capabilities": ["tools": ["listChanged": false]],
                          "serverInfo": ["name": "ohmyagent", "version": "0.1.0"]])
        case "ping":
            return reply(.object([:]))
        case "tools/list":
            let tools = BridgeTool.allCases.filter(enabled.contains).map { tool -> JSONValue in
                ["name": .string(tool.rawValue), "description": .string(tool.summary), "inputSchema": tool.schema]
            }
            return reply(["tools": .array(tools)])
        case "tools/call":
            guard let name = params?["name"]?.stringValue, let tool = BridgeTool(rawValue: name), enabled.contains(tool) else { return fail(-32602, "未知或已禁用的工具") }
            let result = await call(tool, arguments: params?["arguments"] ?? .object([:]), handler: handler)
            Log.bridge.info("Bridge 工具调用", ["tool": name, "isError": "\(result.isError)"])
            return reply(["content": [["type": "text", "text": .string(result.text)]], "isError": .bool(result.isError)])
        default:
            return fail(-32601, "不支持的方法 \(method)")
        }
    }

    private static func call(_ tool: BridgeTool, arguments: JSONValue, handler: any BridgeHandler) async -> BridgeResult {
        switch tool {
        case .openFile:
            guard let path = arguments["path"]?.stringValue, !path.isEmpty else { return BridgeResult("缺少 path 参数", isError: true) }
            return await handler.openFile(path: path, line: arguments["line"]?.intValue)
        case .showDiff:
            guard let path = arguments["path"]?.stringValue, !path.isEmpty else { return BridgeResult("缺少 path 参数", isError: true) }
            return await handler.showDiff(path: path)
        case .getSelection:
            return await handler.selection()
        case .notify:
            guard let message = arguments["message"]?.stringValue, !message.isEmpty else { return BridgeResult("缺少 message 参数", isError: true) }
            return await handler.notify(title: arguments["title"]?.stringValue ?? "OhMyAgent", message: message)
        }
    }
}
