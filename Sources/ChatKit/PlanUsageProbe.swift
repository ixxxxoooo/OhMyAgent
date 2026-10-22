// @author ixxxxoooo
// 主动获取套餐限额(参考 BaoCode):单独启动一个 `claude -p`(stream-json,不落盘会话),
// 发控制请求 `initialize` 与 `get_usage`(即 `/usage` 的数据来源),不调用模型。
// ACP 适配器不转发控制请求,所以不能借用会话自己的进程。

import ACPKit
import AgentHost
import Foundation
import OMLog

/// 套餐限额探测。
public enum PlanUsageProbe {
    /// 关闭后 Claude Code 不会请求用量的环境变量。
    public static let essentialTrafficVariable = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"

    /// 用户是否关闭了非必要流量(此时不主动获取)。
    /// - Parameter environment: claude 运行时的环境变量
    /// - Returns: 关闭时为变量名,否则为 nil
    public static func offBy(environment: [String: String]) -> String? {
        environment[essentialTrafficVariable].map { $0.isEmpty ? nil : essentialTrafficVariable } ?? nil
    }

    /// 启动参数:流式 JSON 收发、不持久化会话。
    static let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence"]

    /// 获取一次限额。
    /// - Parameters:
    ///   - claude: claude 可执行文件路径
    ///   - environment: 运行环境(登录 shell 解析结果)
    ///   - cwd: 工作目录
    ///   - attempts: 响应里还没有限额时的最多询问次数(Claude Code 可能仍在后台获取)
    ///   - retryDelay: 两次询问的间隔
    ///   - timeout: 整体超时
    /// - Returns: 窗口(空数组表示限额不适用);没拿到为 nil
    public static func fetch(claude: String, environment: [String: String], cwd: String,
                             attempts: Int = 3, retryDelay: Duration = .seconds(3), timeout: Duration = .seconds(45)) async -> [RateLimitWindow]? {
        guard !claude.isEmpty, attempts > 0 else { return nil }
        let transport = StdioTransport(launch: ProcessLaunch(executable: claude, arguments: arguments, environment: environment, workingDirectory: cwd))
        let events: AsyncStream<TransportEvent>
        do { events = try transport.start() } catch {
            Log.agent.error("套餐用量探测启动失败", error: error)
            return nil
        }
        // 超时即结束进程,事件流随之结束,下面的读取自然返回
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            transport.stop()
        }
        defer {
            watchdog.cancel()
            transport.stop()
        }
        var reader = ControlReader(iterator: events.makeAsyncIterator())
        guard send(transport, id: "oma-init", subtype: "initialize"), await reader.response(to: "oma-init") != nil else { return nil }
        for attempt in 1...attempts {
            let id = "oma-usage-\(attempt)"
            guard send(transport, id: id, subtype: "get_usage", fields: ["skip_behaviors": true]), let response = await reader.response(to: id) else { return nil }
            if let windows = PlanUsageParser.windows(usageResponse: response) { return windows }
            if attempt < attempts { try? await Task.sleep(for: retryDelay) }
        }
        return nil
    }

    /// 发送一个控制请求。
    /// - Returns: 是否已发出(序列化失败为 false)
    private static func send(_ transport: StdioTransport, id: String, subtype: String, fields: [String: Any] = [:]) -> Bool {
        var request = fields
        request["subtype"] = subtype
        let message: [String: Any] = ["type": "control_request", "request_id": id, "request": request]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        transport.send(data)
        return true
    }
}

/// 按请求 ID 读取控制响应(忽略其余流式消息)。
struct ControlReader {
    var iterator: AsyncStream<TransportEvent>.AsyncIterator

    /// 读到指定请求的响应为止。
    /// - Parameter id: 请求 ID
    /// - Returns: 成功时的响应体;失败、进程退出或超时为 nil
    mutating func response(to id: String) async -> JSONValue? {
        while let event = await iterator.next() {
            switch event {
            case .line(let data):
                StdioTransport.backlog.consumed()
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: data),
                      message["type"]?.stringValue == "control_response",
                      let response = message["response"], response["request_id"]?.stringValue == id else { continue }
                if response["subtype"]?.stringValue == "success" { return response["response"] ?? .object([:]) }
                Log.agent.warning("套餐用量控制请求失败", ["request": id, "error": LogRedactor.truncate(response["error"]?.stringValue ?? "-", limit: 200)])
                return nil
            case .stderr, .message:
                continue
            case .closed:
                return nil
            }
        }
        return nil
    }
}
