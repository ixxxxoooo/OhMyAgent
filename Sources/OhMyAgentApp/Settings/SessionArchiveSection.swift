// @author ixxxxoooo
// 设置 → 通用 → 会话存档:显示本地存档占用,一键清空。

import ChatKit
import DesignSystem
import SwiftUI

/// 会话存档分组(放在设置页的 `SettingsForm` 里)。
struct SessionArchiveSection: View {
    @State private var summary: String?

    var body: some View {
        Section("会话存档") {
            LabeledContent("本地存档", value: summary ?? String(localized: "统计中…"))
            Button("清空会话存档…", role: .destructive) { clear() }
                .buttonStyle(.omDestructive)
                .disabled(SessionModel.archive == nil)
            Note("打开过的会话会在本地保存一份记录,再次打开时直接显示,不必等待 Agent 回放;引擎侧有新内容时会在后台同步。存档不会因 Claude Code 清理旧会话而丢失;删除会话时会一并删除。清空后再次打开会话时会重新从 Agent 拉取。")
        }
        .task { await refresh() }
    }

    /// 后台统计存档占用。
    private func refresh() async {
        guard let archive = SessionModel.archive else {
            summary = String(localized: "未启用")
            return
        }
        let usage = await Task.detached(priority: .utility) { archive.usage() }.value
        let size = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
        summary = String(localized: "\(usage.files) 个会话 · \(size)")
    }

    /// 确认后清空全部存档。
    private func clear() {
        guard let archive = SessionModel.archive,
              OMDialog.confirm(title: String(localized: "清空会话存档"),
                               message: String(localized: "将删除所有会话的本地存档;会话本身不受影响,再次打开时会重新从 Agent 拉取。"),
                               confirmTitle: String(localized: "清空"), destructive: true) else { return }
        Task {
            await archive.removeAll()
            await refresh()
        }
    }
}
