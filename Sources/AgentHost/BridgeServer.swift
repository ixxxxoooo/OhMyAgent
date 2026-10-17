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
    /// 随文本一起返回的图片(PNG,如浏览器截图);作为 MCP 的 image 内容块
    public var imagePNG: Data?

    public init(_ text: String, isError: Bool = false, imagePNG: Data? = nil) {
        self.text = text
        self.isError = isError
        self.imagePNG = imagePNG
    }
}

/// Bridge 工具的客户端实现(由会话模型提供)。
public protocol BridgeHandler: Sendable {
    func openFile(path: String, line: Int?) async -> BridgeResult
    func showDiff(path: String) async -> BridgeResult
    func selection() async -> BridgeResult
    func notify(title: String, message: String) async -> BridgeResult
    /// 扩展工具(Canvas、浏览器、搜索……):参数原样交给实现方解析;默认不支持。
    func callExtended(_ tool: BridgeTool, arguments: JSONValue) async -> BridgeResult
}

public extension BridgeHandler {
    func callExtended(_ tool: BridgeTool, arguments: JSONValue) async -> BridgeResult {
        BridgeResult("当前客户端不支持工具 \(tool.rawValue)", isError: true)
    }
}

/// Bridge 暴露的工具名(设置页可逐个开关)。
public enum BridgeTool: String, CaseIterable, Sendable, Codable {
    case openFile = "open_file"
    case showDiff = "show_diff"
    case getSelection = "get_selection"
    case notify = "notify"
    case canvasCreate = "canvas_create"
    case canvasUpdate = "canvas_update"
    case canvasList = "canvas_list"
    case searchCode = "search_code"
    case browserNavigate = "browser_navigate"
    case browserSnapshot = "browser_snapshot"
    case browserClick = "browser_click"
    case browserType = "browser_type"
    case browserScroll = "browser_scroll"
    case browserScreenshot = "browser_screenshot"
    case browserConsole = "browser_console"
    case browserNetwork = "browser_network"
    case browserTabs = "browser_tabs"

    /// 是否为浏览器类工具(受「浏览器」审批策略管理)。
    public var isBrowser: Bool { rawValue.hasPrefix("browser_") }

    /// 工具说明(给模型看,英文更利于调用)。
    var summary: String {
        switch self {
        case .openFile: return "Open a file in the OhMyAgent editor panel, optionally at a line."
        case .showDiff: return "Show the pending changes of a file made in this session in the OhMyAgent diff viewer."
        case .getSelection: return "Get the text currently selected by the user in the OhMyAgent editor or conversation."
        case .notify: return "Show a macOS notification to the user (use sparingly, e.g. when a long task finishes)."
        case .canvasCreate:
            return "Create a Canvas: a live, reopenable visual artifact shown beside the chat. Prefer it over long markdown when the answer is data-dense "
                + "(tables, metrics, charts), needs images or diagrams, or the user will iterate on it (reports, dashboards, comparisons, audits, timelines). "
                + "Content is a list of blocks. Block types (field `type`): heading{text,level 1-3}, markdown{text}, stats{items:[{label,value,delta?,tone?}]}, "
                + "table{columns:[..],rows:[[..]],title?}, chart{kind: bar|line|area|pie, labels:[..], series:[{name,values:[numbers matching labels]}], title?}, "
                + "callout{tone: info|success|warning|danger, title?, text}, code{language?,text}, image{source: absolute path or https URL, caption?}, "
                + "mermaid{text}, section{title,collapsed?,blocks:[..]}, divider. Returns the canvas id."
        case .canvasUpdate:
            return "Update an existing Canvas by id: change the title, replace all blocks (`blocks`), or add to the end (`append_blocks`). Same block format as canvas_create."
        case .canvasList: return "List existing Canvases (id, title, update time) so you can update or reference one."
        case .searchCode:
            return "Fast indexed text search across the whole workspace (all workspace folders). Returns `path:line: text` per match. Prefer it over grep for broad "
                + "exploration of large repositories: supports regex, whole-word, case sensitivity and a path substring filter. Narrow with `path` if there are too many matches."
        case .browserNavigate:
            return "Open a URL (http/https) in the built-in browser tab for this workspace and wait for it to load. The tab shares one persistent profile per workspace (cookies, logins), "
                + "so you can reach pages the user is already signed in to. Use it to verify web apps you are building (e.g. http://localhost:3000)."
        case .browserSnapshot:
            return "Get a text snapshot of the current page: URL, title and a tree of visible elements. Interactive elements carry a `[ref=eN]` you pass to browser_click / browser_type / browser_scroll. "
                + "Take a new snapshot after the page changes; refs are only valid for the latest snapshot."
        case .browserClick: return "Click the element with the given ref from the latest browser_snapshot."
        case .browserType: return "Type text into the input/textarea with the given ref (replaces its value). Set `submit` to press Enter afterwards."
        case .browserScroll: return "Scroll the page (`direction`: up, down, top, bottom) or scroll the element with `ref` into view."
        case .browserScreenshot: return "Take a screenshot (PNG) of the current page viewport to check layout and visuals."
        case .browserConsole: return "Read recent console messages and uncaught errors of the current page (written since it was opened)."
        case .browserNetwork: return "Read recent network requests (method, URL, status, duration) of the current page, newest last."
        case .browserTabs: return "List the open browser tabs of this workspace (id, title, URL)."
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
        case .canvasCreate:
            return object(["title": ["type": "string"], "blocks": ["type": "array", "items": ["type": "object"]]], required: ["title", "blocks"])
        case .canvasUpdate:
            return object(["id": ["type": "string"], "title": ["type": "string"],
                           "blocks": ["type": "array", "items": ["type": "object"]],
                           "append_blocks": ["type": "array", "items": ["type": "object"]]], required: ["id"])
        case .canvasList: return object([:], required: [])
        case .searchCode:
            return object(["query": ["type": "string", "description": "Text or regular expression to find"],
                           "regex": ["type": "boolean", "description": "Treat query as a regular expression (default false)"],
                           "case_sensitive": ["type": "boolean"], "whole_word": ["type": "boolean"],
                           "path": ["type": "string", "description": "Only search files whose path contains this substring"],
                           "max_results": ["type": "integer", "description": "Max matches to return (1-200, default 50)"]], required: ["query"])
        case .browserNavigate: return object(["url": ["type": "string", "description": "http or https URL; a missing scheme defaults to https (http for localhost)"]], required: ["url"])
        case .browserSnapshot, .browserScreenshot, .browserConsole, .browserNetwork, .browserTabs: return object([:], required: [])
        case .browserClick: return object(["ref": ["type": "string", "description": "Element ref from the latest browser_snapshot, e.g. e12"]], required: ["ref"])
        case .browserType:
            return object(["ref": ["type": "string"], "text": ["type": "string"], "submit": ["type": "boolean", "description": "Press Enter after typing (default false)"]], required: ["ref", "text"])
        case .browserScroll:
            return object(["direction": ["type": "string", "description": "up, down (default), top or bottom"], "ref": ["type": "string", "description": "Scroll this element into view instead"]], required: [])
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
            var content: [JSONValue] = [["type": "text", "text": .string(result.text)]]
            if let image = result.imagePNG { content.append(["type": "image", "data": .string(image.base64EncodedString()), "mimeType": "image/png"]) }
            return reply(["content": .array(content), "isError": .bool(result.isError)])
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
        case .canvasCreate, .canvasUpdate, .canvasList, .searchCode, .browserNavigate, .browserSnapshot, .browserClick, .browserType, .browserScroll, .browserScreenshot, .browserConsole, .browserNetwork, .browserTabs:
            return await handler.callExtended(tool, arguments: arguments)
        }
    }
}
