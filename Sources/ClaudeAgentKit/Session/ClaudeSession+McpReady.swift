// @author ixxxxoooo
// 首条消息前等待 MCP 服务器连接落定:`claude` 在远程 MCP 连上后会追加「工具可用」系统消息,
// 并把此前那条约 1.5 万 token 的上下文消息换一种序列化形式重发,导致提示缓存前缀在第 2 轮整段失效。
// 会话就绪即在后台轮询 `mcp_status`,首条 `session/prompt` 发出前等它结束(最多 `mcpReadyTimeout` 秒)。

import ACPKit
import Foundation
import OMLog

extension ClaudeSession {
    /// 等待 MCP 落定的上限(秒);超时后照常发送,不阻塞用户。
    static let mcpReadyTimeout: Double = 5
    /// 状态轮询间隔(毫秒)。
    private static let mcpReadyPollMs = 150

    /// 判断全部 MCP 服务器是否已落定(没有仍在连接中的)。
    /// - Parameter servers: `mcp_status` 返回的服务器列表
    /// - Returns: 没有 `pending` 状态的服务器时为 true
    static func mcpSettled(_ servers: [JSONValue]) -> Bool {
        !servers.contains { $0["status"]?.stringValue == "pending" }
    }

    /// 会话就绪后启动后台等待(重复调用会取消上一次)。
    func startMcpReadyWait() {
        mcpReadyTask?.cancel()
        guard let query else { mcpReadyTask = nil; return }
        let log = self.log
        mcpReadyTask = Task {
            let started = ContinuousClock.now
            let deadline = started + .seconds(Self.mcpReadyTimeout)
            var settled = false
            while ContinuousClock.now < deadline, !Task.isCancelled {
                guard let servers = try? await query.control("mcp_status")["mcpServers"]?.arrayValue else { settled = true; break }
                if Self.mcpSettled(servers) { settled = true; break }
                do { try await Task.sleep(for: .milliseconds(Self.mcpReadyPollMs)) } catch { return }
            }
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            log.info("MCP 连接等待结束", ["settled": "\(settled)", "ms": "\(ms)"])
        }
    }

    /// 首条消息发出前调用:等后台等待结束(只等一次)。
    func awaitMcpReady() async {
        guard let task = mcpReadyTask else { return }
        await task.value
        mcpReadyTask = nil
    }
}
