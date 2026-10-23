// @author ixxxxoooo
// 原生编辑器与 Agent 的联动:Agent 改动的行内审阅(逐块保留 / 还原)、⌘K 行内编辑、⌘L 引用选区。

import AppKit
import ChatKit
import DiffKit
import EditorCore
import EditorKit
import OMLog
import SwiftUI
import WorkbenchKit

extension FileTabView {
    /// 本文件标签可用的 Agent 会话(⌘K 的模型通道):IDE 窗口取面板会话,Agent 窗口取所属项目的当前会话。
    @MainActor
    func inlineEditSession() -> SessionModel? {
        if let ideHost { return ideHost.session() }
        return workbench.ensureSession(for: projectRoot())
    }

    /// 构造原生编辑器的 Agent 钩子。
    /// - Parameters:
    ///   - doc: 文件文档
    ///   - editorDocument: 共享的 rope 文档
    func agentHooks(_ doc: FileDocument, editorDocument: EditorDocument) -> NativeAgentHooks {
        let path = path
        return NativeAgentHooks(
            review: nativeReview(doc),
            // ⌘K 只在 IDE 窗口接管(Agent 窗口里 ⌘K 仍是全局搜索)
            inlineEdit: doc.isReadOnly || ideHost == nil ? nil : inlineEditGenerator(),
            onReferenceSelection: { range in referenceSelection(range, text: editorDocument.text()) },
            inlineSuggestion: doc.isReadOnly || ideHost == nil ? nil : inlineSuggestionProvider()
        )
    }

    /// ⌘K 的生成闭包:借会话的辅助模型通道改写选区。
    private func inlineEditGenerator() -> NativeInlineEditGenerator {
        let path = path
        return { instruction, selected, before, after in
            guard let session = inlineEditSession() else { throw InlineEditError.unavailable }
            return try await session.inlineEdit(instruction: instruction, path: path, selected: selected, before: before, after: after)
        }
    }

    /// 幽灵补全的提供者:借会话的辅助模型通道请求光标处续写。
    private func inlineSuggestionProvider() -> NativeInlineSuggestionProvider {
        let path = path
        return { prefix, suffix in
            guard let session = inlineEditSession() else { return nil }
            return await session.inlineSuggest(path: path, prefix: prefix, suffix: suffix)
        }
    }

    /// 当前文件的 Agent 改动审阅(仅 IDE 窗口):未保留的块以行内 Diff 呈现,块头条带「保留 / 还原」。
    func nativeReview(_ doc: FileDocument) -> NativeAgentReview? {
        guard let target = reviewTarget(doc) else { return nil }
        let index = min(reviewIndex, target.hunks.count - 1)
        let pending = Set(target.hunks.map(\.id))
        let key = "\(path)|\(target.change.current.hashValue)|\(pending.sorted())"
        let hunks = target.hunks
        let model = target.model, change = target.change
        let actions = [
            NativeDiffAction(title: String(localized: "保留")) { id in
                guard let hunk = hunks.first(where: { $0.id == id }) else { return }
                acceptedHunks.insert(AgentHunkKey.key(hunk))
            },
            NativeDiffAction(title: String(localized: "还原")) { id in model.revert(change, hunks: [id]) },
        ]
        return NativeAgentReview(key: key, diff: change.diff, pending: pending, actions: actions,
                                 title: String(localized: "Agent 更改"), focusHunk: hunks.indices.contains(index) ? hunks[index].id : nil)
    }
}
