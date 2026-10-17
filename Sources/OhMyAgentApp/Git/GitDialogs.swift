// @author ixxxxoooo
// Git 相关的对话框:文本输入与危险操作确认(自绘模态,同步返回,仅在用户点击时调用)。

import AppKit

@MainActor
enum GitDialogs {
    /// 弹出单行文本输入框。
    /// - Parameters:
    ///   - title: 标题
    ///   - message: 说明
    ///   - placeholder: 占位文本
    ///   - confirm: 确认按钮文案
    /// - Returns: 去除首尾空白后的输入;取消或为空返回 nil
    static func prompt(title: String, message: String = "", placeholder: String = "", confirm: String = String(localized: "确定")) -> String? {
        OMDialog.prompt(title: title, message: message, placeholder: placeholder, confirmTitle: confirm)
    }

    /// 危险操作确认。
    /// - Returns: 用户是否确认
    static func confirmDestructive(title: String, message: String, button: String) -> Bool {
        OMDialog.confirm(title: title, message: message, confirmTitle: button, destructive: true)
    }
}
