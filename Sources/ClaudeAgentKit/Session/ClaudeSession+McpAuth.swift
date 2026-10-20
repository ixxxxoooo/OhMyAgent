// @author ixxxxoooo
// MCP 服务器 OAuth:对 ACP 客户端提供、且 Claude 报告为 `needs-auth` 的服务器,向 CLI 申请授权地址,
// 通过 URL 模式的 `elicitation/create` 交给客户端打开浏览器,并轮询服务器状态直到连上(与 Node 适配器一致)。

import ACPKit
import Foundation
import OMLog

extension ClaudeSession {
    /// 授权流程最长等待时间(秒)。
    private static let mcpAuthTimeout: Double = 600
    /// 状态轮询间隔(秒)。
    private static let mcpAuthPoll: Double = 1

    private enum AuthRace: Sendable {
        case completed(Bool)
        case elicitation(accepted: Bool)
    }

    /// 会话创建完成后在后台启动授权(不阻塞 `session/new`)。客户端不支持 URL 征询、或没有 ACP 提供的服务器时不做任何事。
    func startMcpAuthentication() {
        guard caps.elicitationURL, mcpAuthTask == nil, let query else { return }
        let names = Set(spec.mcpServers.compactMap { $0["name"]?.nonEmptyString })
        guard !names.isEmpty else { return }
        mcpAuthTask = Task { [weak self] in
            await self?.authenticateMcpServers(query: query, names: names)
            await self?.finishMcpAuthentication()
        }
    }

    private func finishMcpAuthentication() { mcpAuthTask = nil }

    private func authenticateMcpServers(query: ClaudeQuery, names: Set<String>) async {
        let statuses: [JSONValue]
        do {
            statuses = try await query.control("mcp_status")["mcpServers"]?.arrayValue ?? []
        } catch {
            log.error("读取 MCP 服务器状态失败", error: error)
            return
        }
        for status in statuses {
            guard status["status"]?.stringValue == "needs-auth", let name = status["name"]?.stringValue, names.contains(name) else { continue }
            do { try await authenticateMcpServer(query: query, name: name) } catch {
                if !Task.isCancelled { log.error("MCP 服务器授权失败", error: error, ["server": name]) }
            }
        }
    }

    private func authenticateMcpServer(query: ClaudeQuery, name: String) async throws {
        let login = try await query.control("mcp_authenticate", ["serverName": .string(name)])
        guard login["requiresUserAction"]?.boolValue == true else { return }
        guard let url = login["authUrl"]?.nonEmptyString else {
            throw JSONRPCError(code: JSONRPCError.internalError, message: "Claude Code requested user action without returning an authorization URL")
        }
        let elicitationId = "mcp-oauth-\(UUID().uuidString)"
        let client = self.client
        let sessionId = id
        let request: JSONValue = ["mode": "url", "sessionId": .string(sessionId), "message": .string("Authenticate with MCP server \(name)"),
                                  "url": .string(url), "elicitationId": .string(elicitationId)]
        let first = await withTaskGroup(of: AuthRace?.self) { group -> AuthRace? in
            group.addTask { await Self.waitForMcpConnection(query: query, name: name).map { .completed($0) } }
            group.addTask {
                guard let response = try? await client.request("elicitation/create", request) else { return nil }
                return .elicitation(accepted: response["action"]?.stringValue == "accept")
            }
            var result: AuthRace?
            for await item in group {
                if let item { result = item; break }
            }
            group.cancelAll()
            return result
        }
        switch first {
        case .elicitation(accepted: false), .none: return
        case .elicitation(accepted: true):
            // 用户已在浏览器里确认:等服务器真正连上再通知完成
            _ = await Self.waitForMcpConnection(query: query, name: name)
        case .completed: break
        }
        await client.notify("elicitation/complete", ["elicitationId": .string(elicitationId)])
        log.info("MCP 服务器授权流程结束", ["server": name])
    }

    /// 轮询服务器状态:连上返回 true;失败/禁用/消失或超时返回 false;被取消返回 nil。
    private static func waitForMcpConnection(query: ClaudeQuery, name: String) async -> Bool? {
        let deadline = ContinuousClock.now + .seconds(mcpAuthTimeout)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return nil }
            guard let servers = try? await query.control("mcp_status")["mcpServers"]?.arrayValue,
                  let status = servers.first(where: { $0["name"]?.stringValue == name })?["status"]?.stringValue else { return false }
            if status == "connected" { return true }
            if status == "failed" || status == "disabled" { return false }
            do { try await Task.sleep(for: .seconds(mcpAuthPoll)) } catch { return nil }
        }
        return false
    }
}
