// @author ixxxxoooo
// 计划待批准条(输入框上方):计划本身已作为计划卡放进时间线(默认展开、可编辑),这里只保留决定——
// 各种 Build 方式与「继续规划」。选项按适配器给出的 ID 标注,不再按类别笼统贴标签
// (真实 Claude Code 有 5 个选项:逐项确认 / 自动模式 / 清空上下文后 Build / 跳过权限 / 继续规划)。

import ACPKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 计划待批准条。
struct PlanApprovalCard: View {
    let prompt: PermissionPrompt
    let onChoose: (String) -> Void
    @Environment(SessionModel.self) private var model

    private var document: PlanDocument { prompt.planEntry?.planDocument ?? PlanDocument.parse(markdown: prompt.planText ?? "") }

    var body: some View {
        let plan = document
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image.om("list-todo").foregroundStyle(OMColors.warning)
                Text("计划待批准").font(OMFonts.small.weight(.medium))
                Text(plan.name).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(1).truncationMode(.tail)
                Spacer()
                if let file = prompt.planEntry?.planFileURL {
                    Button { AppEnvironment.shared.workbench.openPlan(path: file.path, title: plan.name) } label: {
                        Image.om("square-pen", size: 12)
                    }
                    .buttonStyle(.omIcon)
                    .omTooltip("在标签页中查看/编辑计划")
                    .accessibilityLabel("在标签页中查看或编辑计划")
                }
                OMCopyButton(help: String(localized: "复制计划"), size: 12) { plan.body }
                Button {
                    // 当前会话保持规划状态(选「继续规划」),计划交给新会话实施
                    if PlanActions.buildInNewSession(plan, fileURL: prompt.planEntry?.planFileURL, from: model),
                       let reject = prompt.request.options.first(where: { $0.kind == .rejectOnce || $0.kind == .rejectAlways }) {
                        onChoose(reject.optionId)
                    }
                } label: {
                    Image.om("git-fork", size: 12)
                }
                .buttonStyle(.omIcon)
                .omTooltip("在新会话中 Build(当前会话保持规划)")
                .accessibilityLabel("在新会话中 Build")
            }
            Text("上面的计划卡里可以查看完整计划;确认没问题再选择 Build。").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            OMFlowLayout(spacing: 8) {
                ForEach(prompt.request.options) { option in
                    Button(Self.label(for: option)) { onChoose(option.optionId) }
                        .buttonStyle(style(for: option))
                        .omTooltip(Self.hint(for: option))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omGlassCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("计划待批准:\(plan.name)")
    }

    /// 选项文案:按适配器的选项 ID 区分(同为「始终允许」类的几种 Build 含义完全不同),未知 ID 退回按类别。
    /// - Parameter option: 权限选项
    static func label(for option: PermissionOption) -> String {
        switch option.optionId {
        case "exit-plan-default": return String(localized: "Build · 逐项确认")
        case "exit-plan-auto": return String(localized: "Build · 自动模式")
        case "exit-plan-clear-auto": return String(localized: "清空上下文后 Build")
        case "exit-plan-bypass": return String(localized: "Build · 跳过权限确认")
        case "opencode-build": return String(localized: "切到 Build 并执行")
        default: break
        }
        switch option.kind {
        case .allowAlways: return String(localized: "Build · 自动接受编辑")
        case .allowOnce: return String(localized: "Build · 逐项确认")
        case .rejectOnce, .rejectAlways: return String(localized: "继续规划")
        default: return option.name
        }
    }

    /// 悬停说明:讲清楚每种 Build 的影响(尤其是会清空上下文、会跳过权限的两种)。
    static func hint(for option: PermissionOption) -> String {
        switch option.optionId {
        case "exit-plan-default": return String(localized: "按计划实施,每次修改文件或运行命令前都问你")
        case "exit-plan-auto": return String(localized: "按计划实施,自动模式下由分类器判断哪些操作无需确认")
        case "exit-plan-clear-auto": return String(localized: "先清空当前对话上下文(计划保留),再用自动模式实施,适合上下文已经很长时")
        case "exit-plan-bypass": return String(localized: "按计划实施,并跳过所有权限确认——只在完全信任这个计划时使用")
        case "opencode-build": return String(localized: "把 OpenCode 切到 build 模式,并让它按上面的计划开始执行")
        default: return option.name
        }
    }

    /// 样式:逐项确认(最稳妥的 Build)是唯一的实心主操作(暖色),其余为次按钮。
    private func style(for option: PermissionOption) -> OMButtonStyle {
        let isPrimary = option.optionId == "exit-plan-default" || option.optionId == "opencode-build"
            || (option.optionId != "exit-plan-auto" && option.optionId != "exit-plan-clear-auto" && option.optionId != "exit-plan-bypass" && option.kind == .allowAlways)
        return isPrimary ? OMButtonStyle(.warm) : OMButtonStyle(.secondary)
    }
}
