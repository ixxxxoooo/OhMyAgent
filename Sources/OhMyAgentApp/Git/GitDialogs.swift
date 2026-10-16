// @author ixxxxoooo
// Git 相关的原生对话框:文本输入与危险操作确认(同步模态,仅在用户点击时调用)。

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
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: String(localized: "取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 危险操作确认。
    /// - Returns: 用户是否确认
    static func confirmDestructive(title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let confirm = alert.addButton(withTitle: button)
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
