// @author ixxxxoooo
// 会话标题自动生成测试:截取、清洗、请求构造、响应解析、来源优先级与会话集成。

import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("会话标题生成")
struct TitleGeneratorTests {
    @Test("截取取首个非空行并折叠空白")
    func fallbackFirstLine() {
        #expect(TitleGenerator.fallbackTitle(from: "\n  帮我   重构路由层  \n第二行") == "帮我 重构路由层")
    }

    @Test("超长截取加省略号,空消息返回 nil")
    func fallbackLimit() {
        let long = String(repeating: "长", count: 80)
        let title = TitleGenerator.fallbackTitle(from: long)
        #expect(title?.hasSuffix("…") == true)
        #expect((title?.count ?? 0) <= TitleGenerator.fallbackLimit + 1)
        #expect(TitleGenerator.fallbackTitle(from: "  \n ") == nil)
    }

    @Test("斜杠命令与 @ 提及前缀被跳过")
    func fallbackSkipsPrefixes() {
        #expect(TitleGenerator.fallbackTitle(from: "/review 检查登录流程") == "检查登录流程")
        #expect(TitleGenerator.fallbackTitle(from: "@Sources/App.swift 解释这个文件") == "解释这个文件")
        #expect(TitleGenerator.fallbackTitle(from: "/help") == nil)
    }

    @Test("清洗模型输出:去前缀、引号、标点,只取首行")
    func cleanGenerated() {
        #expect(TitleGenerator.cleanGenerated("标题:「路由层重构」。\n多余") == "路由层重构")
        #expect(TitleGenerator.cleanGenerated("\"Fix login bug\"") == "Fix login bug")
        #expect(TitleGenerator.cleanGenerated("   \n  ") == nil)
        #expect((TitleGenerator.cleanGenerated(String(repeating: "标", count: 60))?.count ?? 0) <= TitleGenerator.generatedLimit + 1)
    }

    @Test("请求体包含别名、极小 max_tokens、无工具")
    func requestBody() throws {
        let data = try #require(TitleGenerator.requestBody(model: "oma-small", userText: "你好"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["model"] as? String == "oma-small")
        #expect((object["max_tokens"] as? Int ?? 999) <= 64)
        #expect(object["tools"] == nil)
        #expect(object["stream"] as? Bool == false)
    }

    @Test("响应文本解析只取 text 块")
    func responseText() {
        let json = #"{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"路由层重构"}]}"#
        #expect(TitleGenerator.responseText(from: Data(json.utf8)) == "路由层重构")
        #expect(TitleGenerator.responseText(from: Data("{}".utf8)) == nil)
    }

    @Test("来源优先级:手动 > 适配器 > 生成 > 截取")
    func sourceOrdering() {
        #expect(TitleSource.manual > .adapter)
        #expect(TitleSource.adapter > .generated)
        #expect(TitleSource.generated > .truncated)
        #expect(TitleSource.truncated > .none)
    }

    @Test("发送首条消息后立即得到截取标题,并写入自动标题偏好")
    func sessionGetsFallbackTitle() async throws {
        let model = try await M3ScenarioTests.readyModel(workspace: try M3ScenarioTests.tempWorkspace())
        let id = try #require(model.sessionId)
        model.send("请帮我梳理路由层的结构")
        #expect(model.sessionTitle == "请帮我梳理路由层的结构")
        #expect(ClientPrefs.generatedSessionTitles()[id] == "请帮我梳理路由层的结构")
        #expect(await SessionModelTests.wait { !model.isRunning })
        ClientPrefs.setGeneratedSessionTitle(nil, for: id)
        model.shutdown()
    }

    @Test("手动重命名后不会被自动标题覆盖")
    func manualWins() async throws {
        let model = try await M3ScenarioTests.readyModel(workspace: try M3ScenarioTests.tempWorkspace())
        let id = try #require(model.sessionId)
        model.rename(to: "我的标题")
        model.send("另一个话题")
        #expect(model.sessionTitle == "我的标题")
        #expect(await SessionModelTests.wait { !model.isRunning })
        ClientPrefs.setSessionTitle(nil, for: id)
        ClientPrefs.setGeneratedSessionTitle(nil, for: id)
        model.shutdown()
    }
}
