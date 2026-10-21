// @author ixxxxoooo
// 调试钩子 `OMA_AUTOSEND`:按 `||` 分隔依次发送多条消息(上一轮结束后再发下一条),
// 配合 `OMA_AUTOALLOW` 自动批准序列中的全部权限请求;用于无人值守的多轮验证(如 token 消耗实测)。

import ChatKit
import Foundation
import OMLog

/// 自动发送调试钩子。
@MainActor
enum AutoSendHook {
    /// 消息分隔符
    static let separator = "||"

    /// 拆分自动发送文本为消息序列(去空白、丢弃空项)。
    /// - Parameter text: `OMA_AUTOSEND` 的值
    /// - Returns: 依次发送的消息
    static func messages(from text: String) -> [String] {
        text.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 依次发送消息;首条带上输入框里的图片附件。
    /// - Parameters:
    ///   - text: `OMA_AUTOSEND` 的值
    ///   - model: 目标会话
    ///   - autoAllow: 是否自动批准权限请求
    static func run(_ text: String, model: SessionModel, autoAllow: Bool) async {
        for (index, message) in messages(from: text).enumerated() {
            let images = index == 0 ? model.attachments : []
            if index == 0 { model.attachments = [] }
            model.send(message, images: images)
            Log.app.debug("调试钩子:自动发送", ["index": "\(index + 1)"])
            // 等本轮开始再等它结束;期间按需自动批准权限
            for _ in 0..<50 where !model.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            while model.isRunning {
                if autoAllow, let prompt = model.pendingPermissions.first {
                    // 取第一个「允许」类选项(计划批准的选项 ID 不是 allow)
                    let allow = prompt.request.options.first { $0.kind == .allowOnce || $0.kind == .allowAlways }?.optionId ?? "allow"
                    model.resolve(prompt, optionId: allow)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
