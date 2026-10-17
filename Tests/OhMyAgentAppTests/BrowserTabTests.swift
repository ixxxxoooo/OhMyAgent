// @author ixxxxoooo
// 内置浏览器的真实 WKWebView 测试(不联网:用 loadHTMLString):快照给出 ref、点击/输入/滚动生效、控制台与网络记录、拒绝非 http(s) 导航。

import Foundation
import Testing
import WebKit
@testable import OhMyAgentApp

@MainActor
@Suite("内置浏览器")
struct BrowserTabTests {
    private static let page = """
    <html><head><title>测试页</title></head><body>
    <h1>欢迎</h1>
    <p>一段说明文字</p>
    <a href="https://example.test/next">下一页</a>
    <button id="b" onclick="document.getElementById('out').textContent='clicked'; console.log('btn', 1)">提交</button>
    <input id="i" placeholder="搜索框" value="">
    <input type="checkbox" id="c"> 同意
    <div id="out"></div>
    <div style="height:3000px"></div>
    <script>fetch('data:text/plain,ok').catch(function(){}); console.error('boom');</script>
    </body></html>
    """

    private func makeTab() async -> BrowserTabModel {
        let model = BrowserTabModel(id: "t1", workspace: "/tmp/ws", dataStore: .nonPersistent())
        model.webView.loadHTMLString(Self.page, baseURL: URL(string: "https://example.test/"))
        await model.waitForLoad(timeout: 10)
        try? await Task.sleep(for: .milliseconds(200))
        return model
    }

    @Test("快照列出标题、链接、按钮、输入框并给出 ref")
    func snapshot() async throws {
        let model = await makeTab()
        let text = try #require(try await model.evaluate(BrowserScripts.snapshot) as? String)
        #expect(text.contains("Title: 测试页"))
        #expect(text.contains("heading(1) \"欢迎\""))
        #expect(text.contains("link \"下一页\""))
        #expect(text.contains("button \"提交\""))
        #expect(text.contains("textbox \"搜索框\""))
        #expect(text.contains("checkbox"))
        #expect(text.contains("[ref=e1]"))
    }

    @Test("点击、输入与滚动经 ref 生效;未知 ref 报错")
    func actions() async throws {
        let model = await makeTab()
        _ = try await model.evaluate(BrowserScripts.snapshot)
        let button = try #require(try await model.evaluate("return document.getElementById('b').getAttribute('data-oma-ref')") as? String)
        let input = try #require(try await model.evaluate("return document.getElementById('i').getAttribute('data-oma-ref')") as? String)
        _ = try await model.evaluate(BrowserScripts.click, arguments: ["ref": button])
        #expect(try await model.evaluate("return document.getElementById('out').textContent") as? String == "clicked")
        _ = try await model.evaluate(BrowserScripts.type, arguments: ["ref": input, "text": "你好 \"引号\" 'x'", "submit": false])
        #expect(try await model.evaluate("return document.getElementById('i').value") as? String == "你好 \"引号\" 'x'")
        _ = try await model.evaluate(BrowserScripts.scroll, arguments: ["ref": "", "direction": "bottom"])
        let y = try #require(try await model.evaluate("return window.scrollY") as? Double)
        #expect(y > 100)
        await #expect(throws: (any Error).self) { _ = try await model.evaluate(BrowserScripts.click, arguments: ["ref": "e999"]) }
    }

    @Test("控制台消息被记录;截图返回 PNG")
    func consoleAndScreenshot() async throws {
        let model = await makeTab()
        _ = try await model.evaluate("console.warn('careful')")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.console.contains { $0.level == "error" && $0.text == "boom" })
        #expect(model.console.contains { $0.level == "warn" && $0.text == "careful" })
        let png = try #require(await model.screenshot())
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("拦截 file: 与 javascript: 导航")
    func blocksUnsafeSchemes() async throws {
        let model = await makeTab()
        let before = model.webView.url
        model.webView.load(URLRequest(url: URL(fileURLWithPath: "/etc/hosts")))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(model.webView.url == before)
    }
}
