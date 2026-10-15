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

    /// 主窗口(由工作台视图登记;窗口关闭后系统会释放它)
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var openWindowAction: OpenWindowAction?

    /// 由窗口视图捕获环境动作。
    func capture(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    /// 把目录加入工作台(已存在则选中)并前置主窗口。
    func openWorkspace(_ url: URL) {
        Log.app.info("打开项目", ["path": url.path])
        AppEnvironment.shared.workbench.openProject(url)
        showMainWindow()
    }

    /// 打开设置整页(并入主窗口,可深链到某页)。
    func openSettings(page: SettingsPage? = nil, section: ExtensionSection? = nil) {
        if let page { SettingsRouter.shared.go(page, section: section) }
        AppEnvironment.shared.workbench.openSettings()
        showMainWindow()
    }

    /// 打开某个会话(点击通知或托盘菜单):选中项目并请求切换到会话。
    func openSession(workspacePath: String, sessionId: String?, title: String?, uid: String? = nil) {
        Log.app.info("请求打开会话", ["workspace": workspacePath, "session": sessionId ?? "-"])
        if let uid { AttentionCenter.shared.markRead(uid) }
        guard AppEnvironment.shared.workbench.openProject(URL(fileURLWithPath: workspacePath)) != nil else { return }
        sessionRequest = SessionOpenRequest(workspacePath: workspacePath, sessionId: sessionId, title: title)
        showMainWindow()
    }

    /// 在当前项目下开始新对话并前置主窗口。
    func newConversation() {
        let workbench = AppEnvironment.shared.workbench
        if let id = workbench.selectedProjectID { workbench.newConversation(in: id) }
        showMainWindow()
    }

    /// 前置主窗口;窗口已被关闭时重新打开。
    func showMainWindow() {
        NSApp.activate()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: "main")
        }
    }
}
