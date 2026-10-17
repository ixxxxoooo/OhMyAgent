// @author ixxxxoooo
// 提示词优化器:可优化判定、结果清洗、请求体与 claude 参数/输出解析。

import Foundation
import Testing
@testable import ChatKit

@Suite("提示词优化")
struct PromptOptimizerTests {
    @Test("空白、单个斜杠命令、超长草稿不可优化")
    func optimizable() {
        #expect(!PromptOptimizer.isOptimizable(""))
        #expect(!PromptOptimizer.isOptimizable("  \n "))
        #expect(!PromptOptimizer.isOptimizable("/clear"))
        #expect(!PromptOptimizer.isOptimizable(String(repeating: "字", count: PromptOptimizer.maxInputLength + 1)))
        #expect(PromptOptimizer.isOptimizable("修一下登录页的 bug"))
        #expect(PromptOptimizer.isOptimizable("/review 看看这次改动"))
    }

    @Test("清洗:整体围栏、前缀与外层引号被去掉,正文自带代码块保留")
    func cleaning() {
        #expect(PromptOptimizer.clean("```\n修复登录页\n```") == "修复登录页")
        #expect(PromptOptimizer.clean("优化后的提示词:修复登录页") == "修复登录页")
        #expect(PromptOptimizer.clean("“修复登录页”") == "修复登录页")
        #expect(PromptOptimizer.clean("先看这段:\n```swift\nlet a = 1\n```\n再改") == "先看这段:\n```swift\nlet a = 1\n```\n再改")
        #expect(PromptOptimizer.clean("  \n") == nil)
    }

    @Test("请求体带系统提示词、模型别名与原文")
    func requestBody() throws {
        let data = try #require(PromptOptimizer.requestBody(model: "oma-small", text: "改一下 @a.swift"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["model"] as? String == "oma-small")
        #expect(object["system"] as? String == PromptOptimizer.systemPrompt)
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == "改一下 @a.swift")
    }

    @Test("claude 参数:无工具无 MCP;第三方网关环境下不指定模型别名")
    func claudeArguments() {
        let plain = PromptOptimizer.claudeArguments(environment: [:])
        #expect(plain.starts(with: ["-p"]))
        #expect(plain.contains("--strict-mcp-config") && plain.contains("--no-session-persistence"))
        #expect(plain.contains("--model") && plain.contains("haiku"))
        let toolsIndex = plain.firstIndex(of: "--tools")
        #expect(toolsIndex.map { plain[$0 + 1] } == "")
        #expect(!PromptOptimizer.claudeArguments(environment: ["ANTHROPIC_BASE_URL": "https://gw.example"]).contains("--model"))
    }

    @Test("解析 stream-json 的 result 行,忽略其余消息")
    func parseResult() throws {
        let ok = Data(#"{"type":"result","subtype":"success","is_error":false,"result":"更清晰的提示词"}"#.utf8)
        #expect(PromptOptimizer.parseResult(ok)?.text == "更清晰的提示词")
        #expect(PromptOptimizer.parseResult(ok)?.isError == false)
        let failed = Data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":""}"#.utf8)
        #expect(PromptOptimizer.parseResult(failed)?.isError == true)
        #expect(PromptOptimizer.parseResult(Data(#"{"type":"assistant","message":{}}"#.utf8)) == nil)
        #expect(PromptOptimizer.parseResult(Data("not json".utf8)) == nil)
        let message = try #require(PromptOptimizer.userMessage("你好"))
        let object = try #require(try JSONSerialization.jsonObject(with: message) as? [String: Any])
        #expect(object["type"] as? String == "user")
    }

    @Test("演示改写保留原文")
    func demo() {
        #expect(PromptOptimizer.demoRewrite("  修 bug ").hasSuffix("修 bug"))
    }
}
