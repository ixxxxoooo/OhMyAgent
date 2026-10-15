// @author ygw
// 设置页:用量与成本。登录与凭据完全由本机官方 claude 管理,客户端不提供账号 UI。

import ACPKit
import AgentHost
import AppKit
import ChatKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 用量与成本。
struct UsagePage: View {
    let paths: ClaudePaths
    @AppStorage(ClientPrefs.Key.budgetUSD) private var budget = 0.0
    @State private var stats = UsageStatsSnapshot.empty

    var body: some View {
        SettingsForm {
            Section("当前会话") {
                if let model = AppEnvironment.shared.sessionModels.first, let usage = model.usage {
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
