// @author ixxxxoooo
// IDE 窗口里文件标签的附加能力:行末内联 blame、Agent 改动的逐块「保留 / 还原」审阅条。

import ChatKit
import DesignSystem
import DiffKit
import EditorKit
import GitKit
import IconKit
import OMLog
import SwiftUI

/// Agent 改动块的稳定标识:只取增删行文本,不含位置,因此还原其它块后行号移动也保持不变。
enum AgentHunkKey {
    /// - Parameter hunk: 差异块
    /// - Returns: 标识哈希(进程内稳定)
    static func key(_ hunk: DiffHunk) -> Int {
        var hasher = Hasher()
        for line in hunk.lines where line.kind != .context {
            hasher.combine(line.kind == .added)
            hasher.combine(line.text)
        }
        return hasher.finalize()
    }

    /// 尚未被「保留」的块。
    /// - Parameters:
    ///   - hunks: 全部块
    ///   - accepted: 已保留的块标识
    static func pending(_ hunks: [DiffHunk], accepted: Set<Int>) -> [DiffHunk] {
        hunks.filter { !accepted.contains(key($0)) }
    }

    /// 块在新文件里的起始行(第一条新增行;纯删除块取 `newStart`),1 起始。
    static func firstLine(of hunk: DiffHunk) -> Int {
        hunk.lines.first(where: { $0.kind == .added })?.newNumber ?? max(hunk.newStart, 1)
    }
}

extension FileTabView {
    // MARK: 内联 blame

    /// 内联 blame 取哪个仓库:IDE 窗口用窗口的工作区根,Agent 窗口用当前选中的项目。
    var blameRoot: String? { ideHost?.root ?? workbench.selectedProjectID }

    /// 读取 blame(已保存、≤ 1MB 的已跟踪文件;IDE 窗口与 Agent 窗口的文件标签都支持);失败或无仓库时清空。
    func loadBlame(_ doc: FileDocument) async {
        guard let root = blameRoot, !doc.isDirty, let text = doc.text, text.utf8.count <= 1_000_000 else {
            if !blameLines.isEmpty { blameLines = [] }
            ideHost?.blame(path, [])
            return
        }
        let git = GitStore.shared.model(for: root)
        if git.repo == nil { await git.refresh(full: false) }
        guard let repo = git.repo, let relative = repo.relativePath(of: path) else { blameLines = []; ideHost?.blame(path, []); return }
        do {
            let lines = try await repo.blame(path: relative)
            guard !Task.isCancelled else { return }
            blameLines = lines
            ideHost?.blame(path, lines)
        } catch {
            // 未被跟踪的新文件等:没有 blame 属正常,不当作错误
            Log.git.debug("blame 读取失败", ["file": (path as NSString).lastPathComponent, "error": "\(error)"])
            blameLines = []
            ideHost?.blame(path, [])
        }
    }

    /// 某行(0 起始)的内联 blame 文案。
    func blameNote(_ line: Int) -> String? {
        guard blameLines.indices.contains(line) else { return nil }
        let entry = blameLines[line]
        if entry.isUncommitted { return String(localized: "未提交的更改") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "\(entry.author), \(formatter.localizedString(for: entry.date, relativeTo: Date())) • \(entry.summary)"
    }

    // MARK: Agent 改动审阅

    /// 当前文件可审阅的 Agent 改动(文本仍等于 Agent 写入的内容、仍有未保留的块)。
    func reviewTarget(_ doc: FileDocument) -> (model: SessionModel, change: FileChange, hunks: [DiffHunk])? {
        guard ideHost != nil, let found = latestChange(for: path, in: workbench),
              found.change.status == .pending || found.change.status == .partiallyReverted,
              doc.text == found.change.current else { return nil }
        let hunks = AgentHunkKey.pending(found.change.diff.hunks, accepted: acceptedHunks)
        return hunks.isEmpty ? nil : (found.model, found.change, hunks)
    }

    /// 审阅条:逐块上一处/下一处、保留、还原,以及全部保留/全部还原。
    @ViewBuilder
    func agentReviewBar(_ doc: FileDocument) -> some View {
        if let target = reviewTarget(doc) {
            let index = min(reviewIndex, target.hunks.count - 1)
            HStack(spacing: 8) {
                Image.om("sparkles", size: 13).foregroundStyle(OMColors.accentText)
                Text("Agent 更改 \(index + 1)/\(target.hunks.count)").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                Button { step(-1, in: target.hunks) } label: { Image.om("chevron-up", size: 12) }
                    .buttonStyle(OMButtonStyle(.icon))
                    .omTooltip(String(localized: "上一处更改")).accessibilityLabel(String(localized: "上一处更改"))
                Button { step(1, in: target.hunks) } label: { Image.om("chevron-down", size: 12) }
                    .buttonStyle(OMButtonStyle(.icon))
                    .omTooltip(String(localized: "下一处更改")).accessibilityLabel(String(localized: "下一处更改"))
                Spacer()
                // 逐块「保留 / 还原」在编辑器行内块头条上,这里只保留导航与整体操作
                Button("全部还原") { target.model.revert(target.change) }.buttonStyle(.omDestructive)
                Button("全部保留") { target.hunks.forEach { acceptedHunks.insert(AgentHunkKey.key($0)) } }.buttonStyle(.omPrimary)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(OMColors.subtleFill)
        }
    }

    /// 切到上一处/下一处更改并滚动到该块。
    private func step(_ delta: Int, in hunks: [DiffHunk]) {
        guard !hunks.isEmpty else { return }
        let next = (min(reviewIndex, hunks.count - 1) + delta + hunks.count) % hunks.count
        reviewIndex = next
        EditorRouter.goToLine(AgentHunkKey.firstLine(of: hunks[next]), column: 1)
    }
}
