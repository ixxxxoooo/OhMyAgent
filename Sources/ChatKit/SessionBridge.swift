// @author ygw
// 会话与 Bridge 的衔接:把 MCP 工具调用转换为对会话模型的操作,并准备注入 `session/new` 的 MCP 服务器列表。

import ACPKit
import AgentHost
import DiffKit
import Foundation

/// Bridge 工具的会话实现(弱引用会话模型,窗口关闭后调用返回错误)。
final class SessionBridge: BridgeHandler, @unchecked Sendable {
    private weak var model: SessionModel?

    init(model: SessionModel) { self.model = model }

    func openFile(path: String, line: Int?) async -> BridgeResult {
        await MainActor.run { model?.bridgeOpenFile(path: path, line: line) ?? BridgeResult("会话已关闭", isError: true) }
    }

    func showDiff(path: String) async -> BridgeResult {
        await MainActor.run { model?.bridgeShowDiff(path: path) ?? BridgeResult("会话已关闭", isError: true) }
    }

    func selection() async -> BridgeResult {
        await MainActor.run { model?.bridgeSelection() ?? BridgeResult("会话已关闭", isError: true) }
    }

    func notify(title: String, message: String) async -> BridgeResult {
        await MainActor.run { model?.bridgeNotify(title: title, message: message) ?? BridgeResult("会话已关闭", isError: true) }
    }
}

extension SessionModel {
    /// 把工具参数中的路径解析为绝对路径(相对路径以工作区为基准)。
    func resolveBridgePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : (workspace.path as NSString).appendingPathComponent(expanded)
    }

    /// `open_file`:在编辑器面板打开文件。
    func bridgeOpenFile(path: String, line: Int?) -> BridgeResult {
        let full = resolveBridgePath(path)
        guard FileManager.default.isReadableFile(atPath: full) else { return BridgeResult("文件不存在或不可读:\(full)", isError: true) }
        viewerRequest = FileViewRequest(path: full, line: line)
        return BridgeResult("已在 OhMyAgent 中打开 \(full)" + (line.map { "(第 \($0) 行)" } ?? ""))
    }

    /// `show_diff`:提示并打开本会话中改动过的文件。
    func bridgeShowDiff(path: String) -> BridgeResult {
        let full = resolveBridgePath(path)
        guard FileManager.default.isReadableFile(atPath: full) else { return BridgeResult("文件不存在或不可读:\(full)", isError: true) }
        let changed = hasTurnChange(at: full)
        timeline.appendNotice("Agent 请求查看 \((full as NSString).lastPathComponent) 的改动")
        viewerRequest = FileViewRequest(path: full)
        return BridgeResult(changed ? "已打开 \(full);该文件在本轮有改动,可在改动汇总中查看逐块 diff。" : "已打开 \(full);本轮没有记录到该文件的改动。")
    }

    /// `get_selection`:返回用户当前选中的文本。
    func bridgeSelection() -> BridgeResult {
        guard let text = selectedText, !text.isEmpty else { return BridgeResult("用户当前没有选中任何文字。") }
        return BridgeResult(text)
    }

    /// `notify`:交给应用层发送系统通知。
    func bridgeNotify(title: String, message: String) -> BridgeResult {
        guard let notifier else { return BridgeResult("客户端未启用通知", isError: true) }
        notifier(title, message)
        return BridgeResult("已发送通知")
    }

    /// 汇总需要注入会话的 MCP 服务器:Agent-as-MCP 登记项 + OhMyAgent Bridge。
    /// - Parameters:
    ///   - registry: 注册表内容
    ///   - environment: 登录 shell 环境(用于解析命令)
    /// - Returns: MCP 服务器配置与已启动的 Bridge
    func prepareMCPServers(registry: AgentRegistryData, environment: [String: String]) -> (servers: [MCPServerConfig], bridge: BridgeServer?) {
        var servers = registry.enabledMCPAgents.map { $0.serverConfig(path: environment["PATH"] ?? "") }
        var started: BridgeServer?
        if registry.bridge.enabled, let helper = HelperBinaries.locate("OhMyAgentBridge") {
            let server = BridgeServer(socketPath: BridgeServer.makeSocketPath(), handler: SessionBridge(model: self), enabled: registry.bridge.enabledTools)
            if (try? server.start()) != nil {
                started = server
                servers.append(.stdio(name: "ohmyagent", command: helper, args: [], env: ["OMA_BRIDGE_SOCKET": server.socketPath]))
            }
        }
        return (servers, started)
    }
}
