// @author ixxxxoooo
// 把对话会话与应用界面接起来:客户端命令(打开设置/面板/导出/历史)、Skills 与子 Agent 目录。

import AppKit
import ChatKit
import ClaudeConfigKit
import Foundation
import OMLog
import UniformTypeIdentifiers

/// 对话区面板的跨视图请求(如 `/mcp` 命令要求输入区弹出 MCP 面板)。
@MainActor
@Observable
final class ChatPanelRouter {
    static let shared = ChatPanelRouter()

    /// 被请求弹出 MCP 面板的会话
    @ObservationIgnored weak var mcpTarget: SessionModel?
    /// 每次请求自增,视图据此响应
    private(set) var mcpNonce = 0

    /// 请求某个会话弹出 MCP 面板。
    func showMCP(for model: SessionModel) {
        mcpTarget = model
        mcpNonce += 1
    }
}

/// 会话与界面的绑定。
@MainActor
enum ChatBindings {
    /// 给会话安装客户端命令回调与目录来源(幂等)。
    /// - Parameter model: 会话
    static func bind(_ model: SessionModel) {
        model.slashCatalog = { [weak model] in
            guard let model else { return [] }
            return ProjectConfigHub.shared.slashEntries(for: model.workspace)
        }
        model.agentCatalog = { [weak model] in
            guard let model else { return [] }
            return ProjectConfigHub.shared.agentMentions(for: model.workspace)
        }
        model.onLocalCommand = { [weak model] command in
            guard let model else { return }
            handle(command, in: model)
        }
        // 触发一次加载,让补全菜单第一次打开时已有数据
        _ = ProjectConfigHub.shared.center(for: model.workspace)
    }

    /// 执行需要界面的客户端命令。
    private static func handle(_ command: LocalCommand, in model: SessionModel) {
        switch command {
        case .settings(let page):
            AppActions.shared.openSettings(page: SettingsPage(rawValue: page))
        case .extensions(let section):
            AppActions.shared.openSettings(page: .tools, section: ExtensionSection(rawValue: section))
        case .mcpPanel:
            ChatPanelRouter.shared.showMCP(for: model)
        case .history:
            showHistoryMenu(for: model)
        case .exportTranscript:
            exportTranscript(of: model)
        default:
            break
        }
    }

    // MARK: - /resume

    /// 在鼠标位置弹出历史会话菜单。
    private static func showHistoryMenu(for model: SessionModel) {
        model.refreshHistory()
        let menu = NSMenu(title: String(localized: "历史会话"))
        let recent = model.history.prefix(15)
        if recent.isEmpty {
            let empty = NSMenuItem(title: String(localized: "没有历史会话"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let handler = HistoryMenuHandler(model: model)
        for summary in recent {
            let title = summary.title?.isEmpty == false ? summary.title ?? "" : String(localized: "未命名会话")
            let item = NSMenuItem(title: title, action: #selector(HistoryMenuHandler.pick(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = summary.sessionId
            item.state = summary.sessionId == model.sessionId ? .on : .off
            menu.addItem(item)
        }
        // 菜单关闭前保持 handler 存活
        objc_setAssociatedObject(menu, &HistoryMenuHandler.key, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - /export

    /// 把当前对话导出为 Markdown 文件。
    private static func exportTranscript(of model: SessionModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = (model.sessionTitle?.isEmpty == false ? model.sessionTitle ?? "" : String(localized: "OhMyAgent 对话")) + ".md"
        panel.message = String(localized: "导出对话为 Markdown")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = TranscriptExporter.markdown(entries: model.timeline.entries, title: model.sessionTitle, workspace: model.workspace.path)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            model.timeline.appendNotice(String(localized: "对话已导出到 \(url.lastPathComponent)。"))
        } catch {
            Log.app.error("导出对话失败", error: error, ["path": url.path])
            model.timeline.appendNotice(String(localized: "导出失败:\(error.localizedDescription)"), isError: true)
        }
    }
}

/// 历史菜单的动作目标。
@MainActor
final class HistoryMenuHandler: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    private let model: SessionModel

    init(model: SessionModel) { self.model = model }

    @objc func pick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let summary = model.history.first(where: { $0.sessionId == id }) else { return }
        model.openSession(summary)
    }
}
