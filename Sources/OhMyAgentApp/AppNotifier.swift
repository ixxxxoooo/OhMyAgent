// @author ygw
// 系统通知:供 OhMyAgent Bridge 的 notify 工具使用。首次发送时请求授权。

import Foundation
@preconcurrency import UserNotifications

/// 通知发送器。
enum AppNotifier {
    /// 发送一条系统通知(未授权时静默忽略)。
    /// - Parameters:
    ///   - title: 标题
    ///   - message: 正文
    static func send(title: String, message: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
