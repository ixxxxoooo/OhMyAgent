// @author ygw
// 设置页:账号与鉴权、用量与成本。账号信息来自 `claude auth status --json`(不读取任何凭据)。

import ACPKit
import AgentHost
import AppKit
import ChatKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// `claude auth status --json` 的解析结果。
struct AuthStatus: Equatable {
    var loggedIn = false
    var method = ""
    var provider = ""
    var keySource = ""
    var configDirectory = ""

    init?(json: String) {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        loggedIn = object["loggedIn"] as? Bool ?? false
        method = object["authMethod"] as? String ?? ""
        provider = object["apiProvider"] as? String ?? ""
        keySource = object["apiKeySource"] as? String ?? ""
        configDirectory = object["configDirectory"] as? String ?? ""
    }
}

/// 账号与鉴权。
struct AccountPage: View {
    let center: ConfigCenter
    @State private var status: AuthStatus?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        SettingsForm {
            Section("登录状态") {
                if let status {
                    LabeledContent("状态") { HStack { OMStatusDot(status.loggedIn ? .success : .failure); Text(status.loggedIn ? "已登录" : "未登录") } }
                    LabeledContent("方式", value: Self.methodName(status.method))
                    LabeledContent("提供方", value: status.provider)
                    if !status.keySource.isEmpty { LabeledContent("凭据来源", value: status.keySource) }
                } else {
                    Text(message ?? "尚未查询").foregroundStyle(OMColors.secondaryText)
                }
                HStack {
                    Button("刷新状态") { Task { await refresh() } }.disabled(busy || !center.canRunCLI)
                    Button("登录…") { Task { await run(["auth", "login"], "登录") } }.disabled(busy || !center.canRunCLI)
                    Button("退出登录", role: .destructive) { Task { await run(["auth", "logout"], "退出登录") } }.disabled(busy || !center.canRunCLI)
                    if busy { ProgressView().controlSize(.small) }
                }
                Note("登录由官方 claude 完成(可能打开浏览器),OhMyAgent 不会读取、保存或转发你的令牌。")
            }
            Section("当前窗口的会话") {
                if let model = SessionRegistry.shared.models.first {
                    LabeledContent("Agent", value: model.agentName)
                    LabeledContent("状态", value: model.authStatus ?? "未上报")
                    ForEach(model.authMethods) { method in
                        LabeledContent(method.name) { Button("使用此方式登录") { model.authenticate(method) } }
                    }
                } else {
                    Text("没有打开的会话窗口").foregroundStyle(OMColors.secondaryText)
                }
            }
        }
        .task { await refresh() }
    }

    private static func methodName(_ raw: String) -> String {
        switch raw {
        case "api_key_helper": return "API Key 助手脚本"
        case "api_key": return "API Key"
        case "oauth", "claude.ai": return "Claude 订阅账号"
        case "": return "未知"
        default: return raw
        }
    }

    private func refresh() async {
        guard let runner = await runner() else { message = "没有找到 claude 命令行工具"; return }
        busy = true
        defer { busy = false }
        let result = await runner.run(["auth", "status", "--json"], timeout: 20)
        if result.succeeded, let parsed = AuthStatus(json: result.standardOutput) { status = parsed; message = nil }
        else { status = nil; message = result.failureMessage }
    }

    private func run(_ arguments: [String], _ title: String) async {
        guard let runner = await runner() else { return }
        busy = true
        let result = await runner.run(arguments, timeout: 300)
        busy = false
        message = result.succeeded ? nil : "\(title)失败:\(result.failureMessage)"
        await refresh()
    }

    private func runner() async -> CLIRunner? {
        let tools = await Toolchain.shared.resolve()
        return tools.claudePath.map { CLIRunner(executable: $0, environment: tools.environment) }
    }
}

/// 用量与成本。
struct UsagePage: View {
    let paths: ClaudePaths
    @AppStorage(ClientPrefs.Key.budgetUSD) private var budget = 0.0
    @State private var stats = UsageStatsSnapshot.empty

    var body: some View {
        SettingsForm {
            Section("当前会话") {
                if let model = SessionRegistry.shared.models.first, let usage = model.usage {
                    if let used = usage.used {
                        let size = usage.size ?? 0
                        LabeledContent("上下文", value: size > 0 ? "\(used.formatted()) / \(size.formatted()) tokens(\(Int(Double(used) / Double(size) * 100))%)" : "\(used.formatted()) tokens")
                    }
                    if let cost = usage.costAmount {
                        LabeledContent("累计费用", value: "\(cost.formatted(.number.precision(.fractionLength(2...4)))) \(usage.costCurrency ?? "USD")")
                        if budget > 0, cost >= budget { Label("已超过预算提醒阈值 \(budget.formatted()) USD", systemImage: "exclamationmark.triangle.fill").foregroundStyle(OMColors.warning) }
                    }
                } else {
                    Text("当前没有用量数据").foregroundStyle(OMColors.secondaryText)
                }
                LabeledContent("预算提醒(USD)") {
                    TextField("0 表示关闭", value: $budget, format: .number).frame(width: 150).multilineTextAlignment(.trailing)
                }
                Note("预算提醒只在客户端侧判断:会话费用超过阈值时在用量弹层中高亮。订阅账号通常不上报费用。")
            }
            Section("最近活动(来自 claude 的统计缓存)") {
                if stats.daily.isEmpty {
                    Text("没有找到统计数据").foregroundStyle(OMColors.secondaryText)
                } else {
                    let week = stats.recent(days: 7), month = stats.recent(days: 30)
                    LabeledContent("近 7 天", value: "\(week.messages.formatted()) 条消息 · \(week.sessions) 个会话 · \(week.toolCalls.formatted()) 次工具调用")
                    LabeledContent("近 30 天", value: "\(month.messages.formatted()) 条消息 · \(month.sessions) 个会话 · \(month.toolCalls.formatted()) 次工具调用")
                    if let last = stats.lastComputedDate { Note("统计截止 \(last)(由 claude 定期更新)") }
                }
            }
            if !stats.models.isEmpty {
                Section("按模型累计") {
                    ForEach(stats.models) { item in
                        LabeledContent(item.model) {
                            Text("输入 \(item.inputTokens.formatted()) · 输出 \(item.outputTokens.formatted())" + (item.costUSD > 0 ? " · $\(item.costUSD.formatted(.number.precision(.fractionLength(2))))" : ""))
                                .font(OMFonts.small)
                        }
                    }
                }
            }
        }
        .task { stats = await Task.detached { UsageStats.load(paths: paths) }.value }
    }
}
