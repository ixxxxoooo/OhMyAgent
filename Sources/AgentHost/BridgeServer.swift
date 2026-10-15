// @author ygw
// OhMyAgent Bridge:本机 Unix socket 上的 MCP 服务器(换行分隔 JSON-RPC)。
// Agent 通过 stdio 垫片进程 `OhMyAgentBridge` 连接,即可调用客户端能力:打开文件、显示 diff、读取选区、系统通知。

import ACPKit
import Darwin
import Foundation
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

/// Bridge 服务器。
public final class BridgeServer: @unchecked Sendable {
    public let socketPath: String
    private let handler: any BridgeHandler
    private let enabled: Set<BridgeTool>
    private let state = Mutex(State())

    private struct State {
        var listenFD: Int32 = -1
        var running = false
        var connections: Set<Int32> = []
    }

    /// - Parameters:
    ///   - socketPath: socket 文件路径(必须短于 104 字节)
    ///   - handler: 工具实现
    ///   - enabled: 启用的工具
    public init(socketPath: String, handler: any BridgeHandler, enabled: Set<BridgeTool> = Set(BridgeTool.allCases)) {
        self.socketPath = socketPath
        self.handler = handler
        self.enabled = enabled
    }

    /// 生成一个短路径的 socket 文件名。
    public static func makeSocketPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("oma-\(UUID().uuidString.prefix(8).lowercased()).sock")
    }

    /// 清理上次异常退出遗留的 socket 文件(只删除已无人监听的)。
    public static func cleanStaleSockets() {
        let directory = NSTemporaryDirectory()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasPrefix("oma-") && name.hasSuffix(".sock") {
            let path = (directory as NSString).appendingPathComponent(name)
            guard path.utf8.count < 100 else { continue }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in for (index, byte) in path.utf8.enumerated() { buffer[index] = byte } }
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            close(fd)
            if result != 0 { unlink(path) }
        }
    }

    // MARK: - 生命周期

    /// 开始监听。
    public func start() throws {
        let path = socketPath
        guard path.utf8.count < 100 else { throw BridgeError.pathTooLong }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.socket(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw BridgeError.socket(code)
        }
        chmod(path, 0o600)
        state.withLock { $0.listenFD = fd; $0.running = true }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "OhMyAgent.Bridge.accept"
        thread.start()
    }

    /// 停止监听并关闭所有连接。
    public func stop() {
        let (fd, connections) = state.withLock { state -> (Int32, Set<Int32>) in
            state.running = false
            let result = (state.listenFD, state.connections)
            state.listenFD = -1
            state.connections = []
            return result
        }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        for connection in connections { shutdown(connection, SHUT_RDWR) }
        unlink(socketPath)
    }

    private func acceptLoop(_ listenFD: Int32) {
        while state.withLock({ $0.running }) {
            let client = accept(listenFD, nil, nil)
            if client < 0 { if errno == EINTR { continue } else { break } }
            state.withLock { $0.connections.insert(client) }
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "OhMyAgent.Bridge.client"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        let writeLock = Mutex(())
        // 对端关闭写端后,仍要等待在途请求写完响应再关闭连接
        let inflight = DispatchGroup()
        var framer = LineFramer()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            for line in framer.push(Data(buffer[0..<count])) {
                let handler = handler, enabled = enabled
                inflight.enter()
                Task.detached {
                    defer { inflight.leave() }
                    guard let response = await Self.respond(to: line, handler: handler, enabled: enabled) else { return }
                    var data = response
                    data.append(0x0A)
                    writeLock.withLock { _ in Self.writeAll(fd, data) }
                }
            }
        }
        _ = inflight.wait(timeout: .now() + 30)
        state.withLock { _ = $0.connections.remove(fd) }
        close(fd)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
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

/// Bridge 错误。
public enum BridgeError: Error, LocalizedError {
    case pathTooLong
    case socket(Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: return "Bridge socket 路径过长"
        case .socket(let code): return "Bridge socket 失败:\(String(cString: strerror(code)))"
        }
    }
}
