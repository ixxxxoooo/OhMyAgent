// @author ixxxxoooo
// 自动化服务:应用级单例,持有 AutomationCenter(调度与持久化),并把「如何运行一次自动化」接到真实会话上。

import AgentHost
import AutomationKit
import ChatKit
import Foundation
import OMLog

/// 自动化服务。
@MainActor
final class AutomationService {
    static let shared = AutomationService()

    /// 调度中心
    let center: AutomationCenter

    private init() {
        let url = Self.storeURL()
        center = AutomationCenter(fileURL: url) { request in
            let outcome = await AutomationRunner.run(request)
            AutomationService.notifyFinished(request.automation, outcome: outcome)
            return outcome
        }
    }

    /// 持久化文件:演示模式用沙盒目录,否则放在应用支持目录。
    private static func storeURL() -> URL {
        if let demo = DemoLaunch.environment {
            return demo.workbenchStoreURL.deletingLastPathComponent().appendingPathComponent("automations.json")
        }
        return AppEnv.supportDirectory.appendingPathComponent("automations.json")
    }

    /// 应用启动后调用:加载自动化库并开始调度(演示模式只加载,不自动触发)。
    func start() {
        Task {
            await center.load()
            if !DemoLaunch.isActive { center.start() }
        }
    }

    /// 运行结束后发系统通知(取消不通知)。
    private static func notifyFinished(_ automation: Automation, outcome: AutomationRunOutcome) {
        guard outcome.status != .cancelled, !DemoLaunch.isActive else { return }
        let title = String(localized: "自动化「\(automation.name)」\(outcome.status.title)")
        AppNotifier.send(title: title, message: String(outcome.summary.prefix(120)))
    }
}

/// 无界面地跑一次自动化:新建独立会话 → 连接 → 设置权限模式 → 发送提示词 → 等待轮次结束 → 取摘要。
@MainActor
enum AutomationRunner {
    /// 等待连接就绪的最长时间(秒)。
    private static let connectTimeoutSeconds = 90
    /// 等待轮次真正开始的最长时间(秒)。
    private static let startTimeoutSeconds = 30

    /// 运行一次。
    /// - Parameter request: 运行请求
    /// - Returns: 运行结果;任务被取消时返回 `.cancelled`
    static func run(_ request: AutomationRunRequest) async -> AutomationRunOutcome {
        let automation = request.automation
        let log = Log.app.with(["module": "automation", "run": request.run.id.uuidString])
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: automation.projectPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return AutomationRunOutcome(status: .failed, summary: String(localized: "项目目录不存在:\(automation.projectPath)"))
        }
        let model = AppEnvironment.makeSession(workspace: URL(fileURLWithPath: automation.projectPath), descriptor: Toolchain.defaultDescriptor())
        // 独立的注意力中心:无界面会话不应点亮侧栏的运行/未读状态,也不触发「会话完成」通知
        model.attention = AttentionCenter()
        model.notifier = nil
        defer { model.shutdown() }

        model.connect()
        for _ in 0..<(connectTimeoutSeconds * 10) where model.phase != .ready {
            if case .failed(let reason) = model.phase {
                log.warning("自动化连接失败", ["reason": reason])
                return AutomationRunOutcome(status: .failed, summary: reason)
            }
            if Task.isCancelled { return AutomationRunOutcome(status: .cancelled, summary: "") }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard model.phase == .ready else {
            return AutomationRunOutcome(status: .failed, summary: String(localized: "连接 Agent 超时"))
        }
        if let option = model.option(category: "mode"), option.options.contains(where: { $0.value == automation.permissionMode.acpValue }) {
            model.setConfigOption(option.id, value: automation.permissionMode.acpValue, remember: false)
            try? await Task.sleep(for: .milliseconds(400))
        }

        model.send(automation.prompt)
        var started = model.isRunning
        var waited = 0
        while true {
            if Task.isCancelled {
                model.cancel()
                return AutomationRunOutcome(status: .cancelled, summary: summary(of: model), sessionID: model.sessionId)
            }
            rejectUnattendedPrompts(in: model)
            if model.isRunning { started = true } else if started { break }
            waited += 1
            if !started, waited > startTimeoutSeconds * 5 {
                return AutomationRunOutcome(status: .failed, summary: String(localized: "提示词没有被 Agent 接收"), sessionID: model.sessionId)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let text = summary(of: model)
        if let error = lastError(of: model) {
            return AutomationRunOutcome(status: .failed, summary: error, sessionID: model.sessionId)
        }
        return AutomationRunOutcome(status: .succeeded, summary: text, sessionID: model.sessionId)
    }

    /// 无人值守:权限请求一律拒绝,提问直接取消,避免任务悬挂到超时。
    private static func rejectUnattendedPrompts(in model: SessionModel) {
        for prompt in model.pendingPermissions {
            let reject = prompt.request.options.first { $0.kind == .rejectOnce } ?? prompt.request.options.first { $0.kind == .rejectAlways }
            if let reject { model.resolve(prompt, optionId: reject.optionId) } else if let first = prompt.request.options.first { model.resolve(prompt, optionId: first.optionId) }
        }
        for prompt in model.pendingElicitations {
            prompt.cancel()
            model.dismiss(prompt)
        }
    }

    /// 最后一条助手回复的摘要(最多 600 字)。
    private static func summary(of model: SessionModel) -> String {
        let text = model.timeline.entries.last { $0.kind == .assistant && !$0.text.isEmpty }?.text ?? ""
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
    }

    /// 本轮结尾的错误提示(最后一条条目是错误通知时视为失败)。
    private static func lastError(of model: SessionModel) -> String? {
        guard let last = model.timeline.entries.last, last.kind == .notice, last.isError else { return nil }
        return last.text
    }
}
