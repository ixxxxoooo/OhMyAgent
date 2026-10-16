// @author ixxxxoooo
// 会话提示过滤与网关兼容开关。
//
// 背景:经 DeepSeek 等 Anthropic 兼容网关使用 Claude Code 时,CLI 会在 auto 模式下发出
// 「We're changing auto mode to no longer charge for classifier requests … this session isn't eligible」
// 警告(官方说明 https://code.claude.com/docs/en/auto-mode-classifier-billing)。
// 官方给出的办法是设置 `CLAUDE_CODE_AUTO_MODE_SERVER=0`,让分类器请求始终由 Claude Code 自己发起,不再探测服务端检查。
// 本文件提供:① 对第三方网关自动注入该变量;② 兜底过滤(旧 CLI/变量未生效时)这条纯计费噪音。

import ACPKit
import Foundation

/// 会话提示过滤器。
public enum NoticeFilter {
    /// 关闭「服务端 auto 模式分类器」探测的环境变量名。
    public static let autoModeServerKey = "CLAUDE_CODE_AUTO_MODE_SERVER"

    /// 判断提示是否为「auto 模式分类器计费」噪音(与用户无关的网关计费说明)。
    /// - Parameters:
    ///   - title: 提示标题
    ///   - detail: 提示详情(可空)
    /// - Returns: true 表示应当丢弃
    public static func isClassifierBillingNotice(title: String, detail: String?) -> Bool {
        let text = (title + "\n" + (detail ?? "")).lowercased()
        if text.contains("auto-mode-classifier-billing") { return true }
        return text.contains("auto mode") && text.contains("classifier requests")
    }

    /// 判断地址是否为第三方网关(主机不是 Anthropic 官方域名)。
    /// - Parameter baseURL: `ANTHROPIC_BASE_URL`
    /// - Returns: 第三方网关返回 true;无法解析主机时按第三方处理
    public static func isThirdPartyGateway(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(), !host.isEmpty else { return true }
        return !(host == "anthropic.com" || host.hasSuffix(".anthropic.com"))
    }

    /// 为默认配置(~/.claude 里配置了网关)生成只含该开关的会话 `_meta`。
    /// - Parameters:
    ///   - gateway: 当前生效的网关地址(nil 表示直连官方)
    ///   - settingsEnv: `~/.claude/settings.json` 的 env(用户已显式设置则尊重用户)
    ///   - processEnv: 进程环境
    /// - Returns: 需要注入时返回 `_meta`;否则 nil
    public static func gatewayMeta(gateway: URL?, settingsEnv: [String: String], processEnv: [String: String]) -> JSONValue? {
        guard let gateway, isThirdPartyGateway(gateway.absoluteString) else { return nil }
        if settingsEnv[autoModeServerKey] != nil || processEnv[autoModeServerKey] != nil { return nil }
        return .object(["claudeCode": .object(["options": .object(["env": .object([autoModeServerKey: .string("0")])])])])
    }
}
