// @author ygw
// 应用级动作桥:把 SwiftUI 的 openWindow / openSettings 暴露给 AppKit 代码(托盘、通知点击),
// 并承载「打开某个会话」的跨窗口请求。

import ChatKit
import OMLog
import SwiftUI

/// 打开会话请求。
struct SessionOpenRequest: Equatable {
    var workspacePath: String
    var sessionId: String?
    var title: String?
    var nonce = UUID()
}

@MainActor
@Observable
final class AppActions {
    static let shared = AppActions()

    /// 待处理的会话打开请求(由对应工作区窗口消费)
    var sessionRequest: SessionOpenRequest?
    /// 「新对话」请求计数(当前 key 窗口响应)
    var newChatTick = 0

    @ObservationIgnored private var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var openSettingsAction: OpenSettingsAction?

    /// 由窗口视图捕获环境动作。
    func capture(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        openWindowAction = openWindow
        openSettingsAction = openSettings
    }

    /// 打开(或前置)某工作区窗口。
    func openWorkspace(_ url: URL) {
        Log.app.info("打开工作区窗口", ["path": url.path])
        NSApp.activate()
        openWindowAction?(value: url)
    }

    /// 打开设置(可深链到某页)。
    func openSettings(page: SettingsPage? = nil, section: ExtensionSection? = nil) {
        if let page { SettingsRouter.shared.go(page, section: section) }
        NSApp.activate()
        openSettingsAction?()
    }

    /// 打开某个会话(点击通知或托盘菜单):打开工作区窗口并请求切换到会话。
    func openSession(workspacePath: String, sessionId: String?, title: String?, uid: String? = nil) {
        Log.app.info("请求打开会话", ["workspace": workspacePath, "session": sessionId ?? "-"])
        if let uid { AttentionCenter.shared.markRead(uid) }
        sessionRequest = SessionOpenRequest(workspacePath: workspacePath, sessionId: sessionId, title: title)
        openWorkspace(URL(fileURLWithPath: workspacePath))
    }

    /// 前置已有窗口;没有窗口时打开默认工作区。
    func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWorkspace(WorkspaceStore.defaultWorkspace)
        }
    }
}
