// @author ixxxxoooo
// 会话标题:积累首轮上下文,回合结束后请求 CLI 生成标题,读取转录里的自定义标题并以 `session_info_update` 推送。

import ACPKit
import Foundation
import OMLog

extension ClaudeSession {
    static let maxTitleLength = 256
    static let maxTitleContext = 1000
    static let minTitleContext = 10

    /// 标题字符串清洗:折叠空白并截断。
    static func sanitizeTitle(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maxTitleLength else { return collapsed }
        return String(collapsed.prefix(maxTitleLength - 1)) + "…"
    }

    /// 记录提示文本作为标题生成的上下文。
    func noteTitlePrompt(_ blocks: [JSONValue]) {
        guard !titleSettled else { return }
        let text = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
        appendTitleContext("\n\(text)\n")
    }

    /// 记录助手文本。
    func noteTitleAssistant(_ text: String) {
        guard !titleSettled else { return }
        appendTitleContext(text)
    }

    private func appendTitleContext(_ text: String) {
        let next = titleContext + text
        titleContext = next.count > Self.maxTitleContext ? String(next.suffix(Self.maxTitleContext)) : next
    }

    /// 会话重置(`/clear`)后重新评估标题。
    func resetTitles() {
        titleSettled = false
        titleContext = ""
        lastPublishedTitle = nil
    }

    /// 回合结束时:优先用转录里的自定义标题,否则请求 CLI 生成。
    func publishTitleIfNeeded() async {
        guard !closed else { return }
        let info = config.store.info(sessionId: id, cwd: spec.cwd)
        if let custom = info?.customTitle {
            titleSettled = true
            titleContext = ""
            await publishTitle(custom, modified: info?.lastModified ?? Date())
            return
        }
        let fallback = info.flatMap { $0.summary.isEmpty ? nil : ($0.summary, $0.lastModified) }
        if !titleSettled, !cancelled, titleContext.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minTitleContext {
            titleSettled = true
            await requestGeneratedTitle(fallback: fallback)
        } else if let fallback, !titleSettled {
            await publishTitle(fallback.0, modified: fallback.1)
        }
    }

    private func requestGeneratedTitle(fallback: (String, Date)?) async {
        let description = titleContext.trimmingCharacters(in: .whitespacesAndNewlines)
        var title: String?
        do {
            let result = try await query?.control("generate_session_title", ["description": .string(description), "persist": true])
            title = result?["title"]?.nonEmptyString
        } catch {
            log.warning("生成会话标题失败", ["error": error.localizedDescription])
        }
        guard !closed else { return }
        guard let title else {
            titleSettled = false
            if let fallback { await publishTitle(fallback.0, modified: fallback.1) }
            return
        }
        titleContext = ""
        await publishTitle(title, modified: Date())
    }

    /// 推送标题(与上次相同则不重复)。
    func publishTitle(_ raw: String, modified: Date) async {
        let title = Self.sanitizeTitle(raw)
        guard !title.isEmpty, title != lastPublishedTitle else { return }
        lastPublishedTitle = title
        await send(["sessionUpdate": "session_info_update", "title": .string(title), "updatedAt": .string(ISO8601DateFormatter().string(from: modified))])
    }

    /// 客户端经 `_session/rename` 或 `session_info_update` 设置了标题。
    func renameTitle(_ title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JSONRPCError(code: JSONRPCError.invalidParams, message: "标题不能为空") }
        titleSettled = true
        titleContext = ""
        do {
            try await query?.control("rename_session", ["title": .string(trimmed)])
        } catch {
            try config.store.rename(sessionId: id, title: trimmed, cwd: spec.cwd)
        }
        lastPublishedTitle = Self.sanitizeTitle(trimmed)
        await send(["sessionUpdate": "session_info_update", "title": .string(lastPublishedTitle ?? trimmed)])
    }
}
