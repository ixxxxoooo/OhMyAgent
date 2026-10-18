// @author ixxxxoooo
// 选择元素:整理成输入框文字(摘要、选择器、尺寸、样式顺序、HTML 截断、空白压缩)。

import Foundation
import Testing
@testable import ChatKit

@Suite("选择页面元素")
struct PickedElementTests {
    private func element(text: String = "打招呼", html: String = "<button id=\"go\">打招呼</button>") -> PickedElement {
        PickedElement(url: "http://localhost:5173/", title: "首页", tag: "button", selector: "body > div > button#go", text: text, html: html,
                      styles: ["color": "rgb(0, 0, 0)", "background-color": "rgb(238, 238, 255)", "font-size": "16px", "unknown": "x"], width: 78, height: 30, x: 24, y: 190)
    }

    @Test("摘要含标签与文字,文字过长截断;没有文字只显示标签")
    func summary() {
        #expect(element().summary == "<button> \"打招呼\"")
        #expect(element(text: "").summary == "<button>")
        #expect(element(text: String(repeating: "长", count: 100)).summary.contains("…"))
    }

    @Test("输入框文字:包含页面、选择器、尺寸位置、按固定顺序的样式与 HTML;未知样式键不输出")
    func promptText() {
        let text = element().promptText()
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "[浏览器元素] <button> \"打招呼\"")
        #expect(lines.contains("页面:首页 — http://localhost:5173/"))
        #expect(lines.contains("选择器:`body > div > button#go`"))
        #expect(lines.contains("尺寸与位置:78×30 @ (24, 190)"))
        #expect(lines.contains("样式:color: rgb(0, 0, 0); background-color: rgb(238, 238, 255); font-size: 16px"))
        #expect(lines.last == "HTML:`<button id=\"go\">打招呼</button>`")
        #expect(!text.contains("unknown"))
    }

    @Test("HTML 压缩空白并在 1200 字符处截断")
    func htmlClip() {
        let html = "<div>" + String(repeating: "a   b\n", count: 600) + "</div>"
        let text = element(html: html).promptText()
        let htmlLine = text.split(separator: "\n").last.map(String.init) ?? ""
        #expect(htmlLine.hasSuffix("…`") && !htmlLine.contains("   "))
        #expect(htmlLine.count < 1300)
    }
}
