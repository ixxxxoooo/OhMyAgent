// @author ixxxxoooo
// 系统通知:Bridge 的 notify 工具与「会话完成」通知。点击完成通知会定位到对应项目与会话并清除未读点。

import ChatKit
import Foundation
import OMLog
@preconcurrency import UserNotifications

/// 通知发送器与点击处理。
final class AppNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = AppNotifier()

    /// 安装代理(应用启动时调用一次)。
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// 发送一条系统通知(未授权时静默忽略)。
    /// - Parameters:
    ///   - title: 标题
    ///   - message: 正文
    static func send(title: String, message: String) {
        post(title: title, message: message, userInfo: [:])
    }

    /// 发送「会话完成」通知,点击后定位到会话。
    /// - Parameter item: 注意力条目
    static func sendFinished(_ item: AttentionItem) {
        guard ClientPrefs.notifiesOnFinish() else { return }
        post(
            title: String(localized: "\(item.project) 已完成"),
            message: item.title,
            userInfo: ["uid": item.id, "workspace": item.workspacePath, "session": item.sessionId ?? "", "title": item.title]
        )
    }

    private static func post(title: String, message: String, userInfo: [String: String]) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                Log.app.warning("通知未获授权,已忽略", ["title": title, "error": error.map { "\($0)" } ?? "-"])
                return
            }
            Log.app.info("发送系统通知", ["title": title])
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.userInfo = userInfo
            content.sound = userInfo.isEmpty || !ClientPrefs.notifiesWithSound() ? nil : .default
            center.add(UNNotificationRequest(identifier: userInfo["uid"] ?? UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let workspace = info["workspace"] as? String, !workspace.isEmpty else { return }
        let session = (info["session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let title = info["title"] as? String
        let uid = info["uid"] as? String
        Log.app.info("点击完成通知", ["workspace": workspace, "session": session ?? "-"])
        await MainActor.run {
            AppActions.shared.openSession(workspacePath: workspace, sessionId: session, title: title, uid: uid)
        }
    }
}
