// @author ixxxxoooo
// 用户在内置浏览器里「选择元素」得到的页面元素(对齐 Cursor 的 Select Element):
// 把选中的元素连同页面、选择器、HTML 与关键样式整理成一段文字,放进输入框交给 Agent,
// 这样用户可以直接说「把这个按钮改成蓝色」。纯逻辑,页面脚本与界面在应用层。

import Foundation

/// 被选中的页面元素。
public struct PickedElement: Sendable, Equatable {
    public var url: String
    public var title: String
    public var tag: String
    /// 能定位到该元素的 CSS 选择器
    public var selector: String
    /// 元素内的文字(已截断)
    public var text: String
    /// 元素的 outerHTML(已截断)
    public var html: String
    /// 关键计算样式(属性 → 值)
    public var styles: [String: String]
    public var width: Int
    public var height: Int
    public var x: Int
    public var y: Int

    public init(url: String, title: String, tag: String, selector: String, text: String, html: String, styles: [String: String] = [:], width: Int = 0, height: Int = 0, x: Int = 0, y: Int = 0) {
        self.url = url
        self.title = title
        self.tag = tag
        self.selector = selector
        self.text = text
        self.html = html
        self.styles = styles
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }

    /// 一行摘要,如 `<button> "打招呼"`。
    public var summary: String {
        let label = text.isEmpty ? "" : " \"\(Self.clip(text, 40))\""
        return "<\(tag)>\(label)"
    }

    /// 样式输出顺序(只列有值的)。
    static let styleOrder = ["color", "background-color", "font-size", "font-weight", "font-family", "display", "position", "padding", "margin", "border", "border-radius"]

    /// 生成放进输入框的文字。
    public func promptText() -> String {
        var lines = ["[浏览器元素] \(summary)"]
        lines.append("页面:\(title.isEmpty ? "" : title + " — ")\(url)")
        lines.append("选择器:`\(selector)`")
        if width > 0 || height > 0 { lines.append("尺寸与位置:\(width)×\(height) @ (\(x), \(y))") }
        let styleParts = Self.styleOrder.compactMap { key in styles[key].flatMap { $0.isEmpty ? nil : "\(key): \($0)" } }
        if !styleParts.isEmpty { lines.append("样式:" + styleParts.joined(separator: "; ")) }
        lines.append("HTML:`\(Self.clip(html, 1200))`")
        return lines.joined(separator: "\n")
    }

    /// 截断并压缩空白。
    /// - Parameters:
    ///   - text: 原文
    ///   - limit: 最大字符数
    static func clip(_ text: String, _ limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}
