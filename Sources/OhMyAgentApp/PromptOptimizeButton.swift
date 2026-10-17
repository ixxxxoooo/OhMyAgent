// @author ixxxxoooo
// 输入区工具栏最左侧的「优化提示词」按钮:把草稿交给模型改写得更清晰具体,结果直接替换输入框内容,可一键撤销。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 优化提示词按钮。
/// - 草稿可优化时点击开始;优化中显示转圈,再点取消;
/// - 结果写回输入框后,只要草稿仍等于结果,按钮就变成「撤销优化」,一键还原原文。
struct PromptOptimizeButton: View {
    @Bindable var model: SessionModel
    @State private var optimizing: Task<Void, Never>?
    /// 最近一次优化的原文与结果
    @State private var last: Applied?

    /// 一次已应用的优化。
    private struct Applied: Equatable {
        var original: String
        var result: String
    }

    /// 草稿仍等于上次结果时,可撤销。
    private var undoable: Applied? {
        guard let last, model.draft == last.result else { return nil }
        return last
    }

    private var isOptimizing: Bool { optimizing != nil }

    private var canOptimize: Bool { PromptOptimizer.isOptimizable(model.draft) }

    var body: some View {
        let help = helpText
        Button(action: tap) {
            Group {
                if isOptimizing {
                    OMSpinner(.mini)
                } else {
                    Image.om(undoable == nil ? "wand-sparkles" : "undo-2", size: 12)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(OMColors.secondaryText)
        .disabled(!isOptimizing && undoable == nil && !canOptimize)
        .omTooltip(help)
        .accessibilityLabel(help)
        .onDisappear { optimizing?.cancel() }
    }

    private var helpText: String {
        if isOptimizing { return String(localized: "正在优化提示词,点击取消") }
        if undoable != nil { return String(localized: "撤销优化,还原原文") }
        return String(localized: "优化提示词")
    }

    /// 点击:优化中则取消;可撤销则还原;否则开始优化。
    private func tap() {
        if let optimizing {
            optimizing.cancel()
            self.optimizing = nil
            return
        }
        if let undoable {
            model.draft = undoable.original
            last = nil
            return
        }
        guard canOptimize else { return }
        let original = model.draft
        optimizing = Task {
            defer { optimizing = nil }
            do {
                let result = try await model.optimizePrompt(original)
                // 优化期间用户又改了输入:不覆盖他们新写的内容
                guard !Task.isCancelled, model.draft == original else { return }
                last = Applied(original: original, result: result)
                model.draft = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                model.timeline.appendNotice(error.localizedDescription, isError: true)
            }
        }
    }
}
