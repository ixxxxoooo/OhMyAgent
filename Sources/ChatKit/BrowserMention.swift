// @author ixxxxoooo
// `@browser` 提及(对齐 Cursor):用户在消息里写 `@browser`,表示这件事要用内置浏览器去做(测试页面、查布局、看控制台与网络)。
// 用户看到的消息原样不变;发给 Agent 时额外附一个提示块,告诉它用 browser_* 工具,并给出检测到的开发服务器供复用。

import Foundation

/// `@browser` 提及与提示块。
public enum BrowserMention {
    /// 补全里的名称(不含 `@`)。
    public static let handle = "browser"
    /// 提示块的起止标记:历史重放时据此识别并隐藏这个块。
    public static let hintOpen = "<oma-browser-hint>"
    static let hintClose = "</oma-browser-hint>"

    /// 文本里是否提到了 `@browser`(要求 `@` 在开头或空白之后,且后面不是名称字符)。
    /// - Parameter text: 用户消息
    public static func isMentioned(in text: String) -> Bool {
        text.range(of: #"(^|\s)@browser(?![A-Za-z0-9_-])"#, options: .regularExpression) != nil
    }

    /// 是否是我们附加的提示块(历史重放时不显示)。
    /// - Parameter text: 文本块内容
    public static func isHint(_ text: String) -> Bool { text.hasPrefix(hintOpen) }

    /// 生成提示块文本。
    /// - Parameter servers: 检测到的开发服务器
    public static func hint(servers: [DevServer]) -> String {
        var lines = [
            hintOpen,
            "The user referenced @browser: do this task with the built-in browser tools (browser_navigate, browser_snapshot, browser_click, browser_type, browser_hover, "
                + "browser_scroll, browser_screenshot, browser_console, browser_network, browser_back/forward/reload) instead of only describing what you would do.",
        ]
        if servers.isEmpty {
            lines.append("No running dev server was detected on this machine. If the task needs one, check `lsof -nP -iTCP -sTCP:LISTEN` first and only start one if none fits.")
        } else {
            lines.append("Dev servers already running on this machine — reuse their port, do NOT start a duplicate:")
            for server in servers {
                lines.append("- \(server.url) (\(server.command)\(server.cwd.map { ", cwd \($0)" } ?? ""))")
            }
        }
        lines.append("Workflow: navigate, take a browser_snapshot, interact, then verify with browser_screenshot; read browser_console / browser_network when something looks wrong.")
        lines.append(hintClose)
        return lines.joined(separator: "\n")
    }
}
