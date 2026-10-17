// @author ixxxxoooo
// Bridge 工具结果带图片时,以 MCP image 内容块返回。

import ACPKit
import Foundation
import Testing
@testable import AgentHost

@Suite("Bridge 图片结果")
struct BridgeImageTests {
    private struct Handler: BridgeHandler {
        func openFile(path: String, line: Int?) async -> BridgeResult { BridgeResult("") }
        func showDiff(path: String) async -> BridgeResult { BridgeResult("") }
        func selection() async -> BridgeResult { BridgeResult("") }
        func notify(title: String, message: String) async -> BridgeResult { BridgeResult("") }
        func callExtended(_ tool: BridgeTool, arguments: JSONValue) async -> BridgeResult { BridgeResult("shot", imagePNG: Data([1, 2, 3])) }
    }

    @Test("截图以 image 内容块返回")
    func imageContent() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser_screenshot","arguments":{}}}"#.utf8)
        let data = try #require(await BridgeServer.respond(to: request, handler: Handler(), enabled: Set(BridgeTool.allCases)))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let content = try #require(json["result"]?["content"]?.arrayValue)
        #expect(content.count == 2)
        #expect(content[1]["type"]?.stringValue == "image")
        #expect(content[1]["data"]?.stringValue == Data([1, 2, 3]).base64EncodedString())
    }

    @Test("浏览器工具都出现在 tools/list 且 Schema 完整")
    func listsBrowserTools() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)
        let data = try #require(await BridgeServer.respond(to: request, handler: Handler(), enabled: Set(BridgeTool.allCases)))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let names = (json["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        for name in ["browser_navigate", "browser_snapshot", "browser_click", "browser_type", "browser_scroll", "browser_screenshot", "browser_console", "browser_network", "browser_tabs"] {
            #expect(names.contains(name))
        }
    }
}
