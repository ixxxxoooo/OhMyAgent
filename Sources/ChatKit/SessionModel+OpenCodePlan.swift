// @author ixxxxoooo
// OpenCode 计划模式的「计划批准」:OpenCode 的 plan 模式没有 Claude Code 那样的 ExitPlanMode 权限请求,
// 计划只是一段普通回复。这里在回合正常结束时,把本轮最后一段像计划的回复合成一张计划卡(待批准),
// 让用户选择「切到 Build 执行」或「继续规划」,与 Claude Code 的计划批准体验一致。

import ACPKit
import Foundation
import OMLog

/// OpenCode 计划批准的纯逻辑(判断是否该提出计划、取计划文本),与会话状态无关,便于测试。
@MainActor
enum OpenCodePlan {
    /// 「切到 Build 执行」选项 ID
    static let buildOptionId = "opencode-build"
    /// 「继续规划」选项 ID
    static let keepOptionId = "opencode-keep"
    /// 计划文本的最短长度:更短的回复多半是澄清问题或闲聊
    static let minimumLength = 200

    /// 回复是否像一份计划:足够长,且至少有 3 行标题或列表项。
    /// - Parameter text: 助手回复(Markdown)
    static func looksLikePlan(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else { return false }
        let structured = trimmed.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("* ") { return true }
            // 有序列表:数字 + "." / "、" / ")"
            let digits = line.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 3 else { return false }
            let rest = line.dropFirst(digits.count)
            return rest.hasPrefix(".") || rest.hasPrefix("、") || rest.hasPrefix(")")
        }
        return structured.count >= 3
    }

    /// 本轮(最后一条用户消息之后)最后一段助手回复;本轮已经有计划卡则返回 nil(不重复提出)。
    /// - Parameter entries: 时间线条目
    static func lastAssistantText(in entries: [TimelineEntry]) -> String? {
        for entry in entries.reversed() {
            switch entry.kind {
            case .user: return nil
            case .planDoc: return nil
            case .assistant:
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            default: continue
            }
        }
        return nil
    }

    /// 合成的计划批准请求:与 Claude Code 的 ExitPlanMode 同构(计划文本在 `rawInput.plan`),复用同一张计划卡。
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - plan: 计划文本
    /// - Returns: 权限请求;构造失败为 nil
    static func request(sessionId: String, plan: String) -> PermissionRequest? {
        let json: JSONValue = .object([
            "sessionId": .string(sessionId),
            "toolCall": .object([
                "toolCallId": .string("oma-plan-" + UUID().uuidString),
                "title": .string("计划"),
                "kind": .string("switch_mode"),
                "name": .string("ExitPlanMode"),
                "rawInput": .object(["plan": .string(plan)]),
            ]),
            "options": .array([
                .object(["optionId": .string(buildOptionId), "name": .string("Build"), "kind": .string("allow_once")]),
                .object(["optionId": .string(keepOptionId), "name": .string("继续规划"), "kind": .string("reject_once")]),
            ]),
        ])
        return PermissionRequest(json: json)
    }
}

extension SessionModel {
    /// 是否在用 OpenCode(描述符 ID 或启动命令是 opencode / opencode2 等)。
    private var isOpenCode: Bool {
        if activeDescriptor.id == "opencode" { return true }
        let name = ((activeDescriptor.command ?? "") as NSString).lastPathComponent
        return name.hasPrefix("opencode") && name.dropFirst("opencode".count).allSatisfy(\.isNumber)
    }

    /// 回合正常结束后调用:OpenCode 处于 plan 模式、且本轮最后一段回复像一份计划时,提出计划批准。
    func proposeOpenCodePlanIfNeeded() {
        guard isOpenCode, option(category: "mode")?.currentValue.stringValue == "plan",
              pendingPermissions.isEmpty, pendingElicitations.isEmpty,
              let sessionId, let plan = OpenCodePlan.lastAssistantText(in: timeline.entries), OpenCodePlan.looksLikePlan(plan),
              let request = OpenCodePlan.request(sessionId: sessionId, plan: plan) else { return }
        log.info("OpenCode 计划模式:提出计划批准", ["chars": "\(plan.count)"])
        Task { [weak self] in
            let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionOutcome, Never>) in
                guard let self else { continuation.resume(returning: .cancelled); return }
                let prompt = PermissionPrompt(request: request, continuation: continuation)
                self.proposePlanIfNeeded(for: prompt)
                self.pendingPermissions.append(prompt)
            }
            guard let self, case .selected(let optionId) = outcome, optionId == OpenCodePlan.buildOptionId else { return }
            await self.buildOpenCodePlan()
        }
    }

    /// 切到 Build 模式并让 Agent 按计划执行。
    private func buildOpenCodePlan() async {
        guard let modeOption = option(category: "mode"),
              let build = modeOption.options.first(where: { $0.value == "build" }) ?? modeOption.options.first(where: { $0.value != "plan" }) else {
            timeline.appendNotice(String(localized: "找不到可用于执行计划的模式,请手动切换到 build 后发送「按计划执行」。"), severity: "warning")
            return
        }
        setConfigOption(modeOption.id, value: build.value)
        // 等模式切换生效(配置回包后更新),再发送,避免首条消息仍在 plan 模式下跑
        for _ in 0..<30 where option(category: "mode")?.currentValue.stringValue != build.value {
            try? await Task.sleep(for: .milliseconds(100))
        }
        send(String(localized: "请按上面的计划开始执行。"))
    }
}
