// @author ixxxxoooo
// 命令输出整形(去围栏/保留末尾)与网关「auto 模式分类器计费」提示的处理。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@Suite("命令输出整形")
struct ToolOutputTests {
    @Test("去掉适配器包裹的 ```console 围栏")
    func stripFence() {
        let wrapped = "```console\n=== a ===\nline 2\n```"
        #expect(ToolOutputText.stripFence(wrapped) == "=== a ===\nline 2")
        // 首尾有空行也能识别
        #expect(ToolOutputText.stripFence("\n```\nx\n```\n\n") == "x")
        // 无围栏、只有开头围栏、内容里带围栏均原样返回
        #expect(ToolOutputText.stripFence("plain\ntext") == "plain\ntext")
        #expect(ToolOutputText.stripFence("```sh\nopen only") == "```sh\nopen only")
        #expect(ToolOutputText.stripFence("a\n```\nb\n```\nc") == "a\n```\nb\n```\nc")
    }

    @Test("保留末尾若干行并统计省略数")
    func tail() {
        let text = (1...10).map(String.init).joined(separator: "\n") + "\n"
        let slice = ToolOutputText.tail(text, maxLines: 4)
        #expect(slice.totalLines == 10)
        #expect(slice.omittedLines == 6)
        #expect(slice.text == "7\n8\n9\n10")
        let whole = ToolOutputText.tail("a\nb", maxLines: 5)
        #expect(whole.omittedLines == 0)
        #expect(whole.text == "a\nb")
    }
}

@Suite("DeepSeek 等网关的 auto 模式分类器提示")
struct GatewayNoticeTests {
    static let warning = "We're changing auto mode to no longer charge for classifier requests in Claude Code. However, this session isn't eligible because your requests go through api.deepseek.com, which isn't compatible with this update. To fix it ask your gateway to implement: https://code.claude.com/docs/en/auto-mode-classifier-billing"

    @Test("识别计费噪音提示,不误伤普通提示")
    func detect() {
        #expect(NoticeFilter.isClassifierBillingNotice(title: "Claude reported a warning", detail: Self.warning))
        #expect(NoticeFilter.isClassifierBillingNotice(title: Self.warning, detail: nil))
        #expect(!NoticeFilter.isClassifierBillingNotice(title: "上下文已压缩", detail: "旧消息已被摘要"))
        #expect(!NoticeFilter.isClassifierBillingNotice(title: "Auto mode is on", detail: nil))
    }

    @Test("时间线丢弃该提示,保留其他提示")
    @MainActor
    func timelineDrops() {
        let store = TimelineStore()
        store.apply(.notice(severity: "warning", title: "Claude reported a warning", detail: Self.warning))
        #expect(store.entries.isEmpty)
        store.apply(.notice(severity: "warning", title: "上下文已压缩", detail: "旧消息已被摘要"))
        #expect(store.entries.count == 1)
    }

    @Test("第三方网关判定")
    func thirdParty() {
        #expect(NoticeFilter.isThirdPartyGateway("https://api.deepseek.com/anthropic"))
        #expect(NoticeFilter.isThirdPartyGateway("http://127.0.0.1:3456"))
        #expect(!NoticeFilter.isThirdPartyGateway("https://api.anthropic.com"))
        #expect(!NoticeFilter.isThirdPartyGateway("https://eu.api.anthropic.com/v1"))
    }

    @Test("提供商会话环境:第三方网关关闭服务端分类器探测,官方 API 不改动")
    func providerEnvironment() {
        let deepseek = ModelProvider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-chat")
        #expect(ProviderLaunch.publicEnvironment(deepseek)[NoticeFilter.autoModeServerKey] == "0")
        let official = ModelProvider(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com", model: "claude-sonnet-4-5", usesAPIKeyHeader: true)
        #expect(ProviderLaunch.publicEnvironment(official)[NoticeFilter.autoModeServerKey] == nil)
    }

    @Test("默认配置走第三方网关时注入开关,用户已显式设置则尊重")
    func defaultGatewayMeta() throws {
        let gateway = try #require(URL(string: "https://api.deepseek.com/anthropic"))
        let meta = NoticeFilter.gatewayMeta(gateway: gateway, settingsEnv: [:], processEnv: [:])
        let env = meta?.objectValue?["claudeCode"]?.objectValue?["options"]?.objectValue?["env"]?.objectValue
        #expect(env?[NoticeFilter.autoModeServerKey]?.stringValue == "0")
        #expect(NoticeFilter.gatewayMeta(gateway: gateway, settingsEnv: [NoticeFilter.autoModeServerKey: "1"], processEnv: [:]) == nil)
        #expect(NoticeFilter.gatewayMeta(gateway: nil, settingsEnv: [:], processEnv: [:]) == nil)
        let official = try #require(URL(string: "https://api.anthropic.com"))
        #expect(NoticeFilter.gatewayMeta(gateway: official, settingsEnv: [:], processEnv: [:]) == nil)
    }
}
