// @author ixxxxoooo
// 浏览器 Bridge 工具:地址规整与入参解析。

import ACPKit
import AgentHost
import Foundation
import Testing
@testable import ChatKit

@Suite("浏览器工具入参")
struct BrowserBridgeTests {
    @Test("谷歌香港站改写为 ncr 入口")
    func googleNoCountryRedirect() {
        #expect(BrowserArguments.googleNoCountryRedirect(URL(string: "https://www.google.com.hk/?gws_rd=cr")!)?.absoluteString == "https://www.google.com/ncr")
        #expect(BrowserArguments.googleNoCountryRedirect(URL(string: "https://www.google.com.hk/search?q=a")!)?.absoluteString == "https://www.google.com/search?q=a")
        #expect(BrowserArguments.googleNoCountryRedirect(URL(string: "https://www.google.com/")!) == nil)
    }

    @Test("地址规整:补协议、本机用 http、拒绝危险协议")
    func normalize() {
        #expect(BrowserArguments.normalize("example.com")?.absoluteString == "https://example.com")
        #expect(BrowserArguments.normalize("  https://a.dev/x?y=1 ")?.absoluteString == "https://a.dev/x?y=1")
        #expect(BrowserArguments.normalize("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(BrowserArguments.normalize("127.0.0.1:8080/p")?.absoluteString == "http://127.0.0.1:8080/p")
        #expect(BrowserArguments.normalize("example.com:8443/a")?.absoluteString == "https://example.com:8443/a")
        #expect(BrowserArguments.normalize("javascript:alert(1)") == nil)
        #expect(BrowserArguments.normalize("data:text/html,hi") == nil)
        #expect(BrowserArguments.normalize("file:///etc/passwd") == nil)
        #expect(BrowserArguments.normalize("ftp://a.com") == nil)
        #expect(BrowserArguments.normalize("mailto:a@b.com") == nil)
        #expect(BrowserArguments.normalize("") == nil)
        #expect(BrowserArguments.normalize("a.com\nb.com") == nil)
        #expect(BrowserArguments.normalize("http://") == nil)
    }

    @Test("各工具入参解析")
    func parse() throws {
        #expect(try BrowserArguments.parse(.browserNavigate, ["url": "a.com"]).get() == .navigate(url: URL(string: "https://a.com")!))
        #expect(throws: BrowserParseError.self) { try BrowserArguments.parse(.browserNavigate, ["url": "javascript:1"]).get() }
        #expect(try BrowserArguments.parse(.browserClick, ["ref": "e12"]).get() == .click(ref: "e12", button: .left, double: false))
        #expect(try BrowserArguments.parse(.browserClick, ["ref": "e12", "button": "RIGHT"]).get() == .click(ref: "e12", button: .right, double: false))
        #expect(try BrowserArguments.parse(.browserClick, ["ref": "e12", "double": true]).get() == .click(ref: "e12", button: .left, double: true))
        #expect(throws: BrowserParseError.self) { try BrowserArguments.parse(.browserClick, ["ref": "e12", "button": "middle"]).get() }
        #expect(try BrowserArguments.parse(.browserHover, ["ref": "e4"]).get() == .hover(ref: "e4"))
        #expect(throws: BrowserParseError.self) { try BrowserArguments.parse(.browserHover, [:]).get() }
        #expect(try BrowserArguments.parse(.browserBack, [:]).get() == .history(.back))
        #expect(try BrowserArguments.parse(.browserForward, [:]).get() == .history(.forward))
        #expect(try BrowserArguments.parse(.browserReload, [:]).get() == .history(.reload))
        #expect(throws: BrowserParseError.self) { try BrowserArguments.parse(.browserClick, ["ref": "e1\"]x"]).get() }
        #expect(throws: BrowserParseError.self) { try BrowserArguments.parse(.browserClick, [:]).get() }
        #expect(try BrowserArguments.parse(.browserType, ["ref": "e3", "text": "hi", "submit": true]).get() == .type(ref: "e3", text: "hi", submit: true))
        #expect(try BrowserArguments.parse(.browserType, ["ref": "e3", "text": "hi"]).get() == .type(ref: "e3", text: "hi", submit: false))
        #expect(try BrowserArguments.parse(.browserScroll, [:]).get() == .scroll(.down))
        #expect(try BrowserArguments.parse(.browserScroll, ["direction": "TOP"]).get() == .scroll(.top))
        #expect(try BrowserArguments.parse(.browserScroll, ["ref": "e9"]).get() == .scroll(.element(ref: "e9")))
        #expect(throws: BrowserParseError.self) { try BrowserArguments.parse(.browserScroll, ["direction": "left"]).get() }
        #expect(try BrowserArguments.parse(.browserSnapshot, [:]).get() == .snapshot)
        let browserTools = BridgeTool.allCases.filter { $0.rawValue.hasPrefix("browser_") }
        #expect(browserTools.count == 13)
        for tool in browserTools { #expect(tool.isBrowser) }
    }
}

@Suite("浏览器日志呈现")
struct BrowserLogFormatTests {
    @Test("行数不多时原样返回;为空时给空文案")
    func inline() {
        #expect(BrowserLogFormat.render(lines: [], noun: "x", empty: "none", filePath: nil) == "none")
        #expect(BrowserLogFormat.render(lines: ["a", "b"], noun: "x", empty: "none", filePath: nil) == "a\nb")
        #expect(!BrowserLogFormat.needsFile(BrowserLogFormat.inlineLimit) && BrowserLogFormat.needsFile(BrowserLogFormat.inlineLimit + 1))
    }

    @Test("日志太长:只返回总行数、最近预览与文件路径,不含更早的行")
    func truncated() {
        let lines = (1...200).map { "line \($0)" }
        let text = BrowserLogFormat.render(lines: lines, noun: "console messages", empty: "none", filePath: "/tmp/x.log")
        #expect(text.contains("200 console messages") && text.contains("/tmp/x.log"))
        #expect(text.contains("line 200") && text.contains("line \(200 - BrowserLogFormat.previewCount + 1)"))
        #expect(!text.contains("line 100\n") && !text.hasSuffix("line 1"))
        #expect(text.split(separator: "\n").count == 1 + BrowserLogFormat.previewCount)
    }

    @Test("载荷预览按长度截断并标明剩余字符数;network 的 request 参数必须是正整数")
    func clipAndParse() throws {
        #expect(BrowserLogFormat.clip("abc", limit: 10) == "abc")
        #expect(BrowserLogFormat.clip(String(repeating: "x", count: 15), limit: 10).hasSuffix("… (5 more characters)"))
        #expect(try BrowserArguments.parse(.browserNetwork, [:]).get() == .network())
        #expect(try BrowserArguments.parse(.browserNetwork, ["request": 3]).get() == .network(request: 3))
        #expect(throws: BrowserParseError.self) { try BrowserArguments.parse(.browserNetwork, ["request": 0]).get() }
        #expect(throws: BrowserParseError.self) { try BrowserArguments.parse(.browserNetwork, ["request": "abc"]).get() }
    }
}
