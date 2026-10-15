// @author ygw
// 输入区:玻璃浮层,包含输入框、模式/模型菜单、发送与停止按钮。

import ACPKit
import ChatKit
import DesignSystem
import SwiftUI

/// 输入区视图。
struct ComposerView: View {
    @Bindable var model: SessionModel
    @State private var textHeight: CGFloat = 34
    @State private var controller = ComposerController()
    @State private var completion: CompletionContext?
    @State private var items: [CompletionItem] = []
    @State private var selected = 0
    @State private var dismissedAt: String?
    @State private var lookup: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            ComposerTextView(
                text: $model.draft,
                height: $textHeight,
                placeholder: placeholder,
                onSubmit: { model.sendDraft() },
                onEscape: { if model.isRunning { model.cancel() } },
                controller: controller,
                isCompletionActive: { completion != nil && !items.isEmpty },
                onCompletionKey: handleCompletionKey,
                onBacktab: { model.cycleMode() },
                onEdit: updateCompletion,
                onSelectionText: { model.selectedText = $0 }
            )
            .frame(height: textHeight)
            HStack(spacing: 6) {
                OptionMenu(model: model, category: "mode", icon: "slider.horizontal.3")
                OptionMenu(model: model, category: "model", icon: "cpu")
                OptionMenu(model: model, category: "thought_level", icon: "brain")
                Spacer(minLength: 8)
                if let queued = model.queuedPrompt {
                    Text("连接后发送:\(queued)")
                        .font(OMFonts.caption)
                        .foregroundStyle(OMColors.secondaryText)
                        .lineLimit(1)
                }
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .omGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topLeading) {
            if completion != nil, !items.isEmpty {
                let popup = CompletionPopup(items: items, selected: selected, onPick: accept)
                popup
                    .offset(x: 4, y: -(popup.height + 8))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: items.isEmpty)
    }

    // MARK: - 补全

    /// 文本或光标变化:重新计算补全上下文并异步取候选。
    private func updateCompletion(text: String, cursor: Int) {
        guard let context = CompletionEngine.context(text: text, cursor: cursor), dismissedAt != text else {
            if completion != nil { completion = nil; items = []; lookup?.cancel() }
            if dismissedAt != text { dismissedAt = nil }
            return
        }
        lookup?.cancel()
        lookup = Task {
            let result = await model.completionItems(for: context)
            guard !Task.isCancelled else { return }
            completion = context
            items = result
            selected = 0
        }
    }

    private func handleCompletionKey(_ key: CompletionKey) {
        switch key {
        case .up: selected = items.isEmpty ? 0 : (selected - 1 + items.count) % items.count
        case .down: selected = items.isEmpty ? 0 : (selected + 1) % items.count
        case .accept: if items.indices.contains(selected) { accept(items[selected]) }
        case .dismiss:
            dismissedAt = model.draft
            completion = nil
            items = []
        }
    }

    /// 接受候选:替换触发范围内的文本。
    private func accept(_ item: CompletionItem) {
        guard let context = completion else { return }
        var text = item.insertText
        if context.trigger == .slash, item.kind == .agentCommand { text += " " }
        completion = nil
        items = []
        controller.replace(range: context.range, with: text)
    }

    private var placeholder: String {
        switch model.phase {
        case .connecting: return "正在连接 Agent,可以先输入…"
        case .failed: return "Agent 未连接,发送将尝试重新连接"
        default: return "向 \(model.agentName) 提问,Return 发送,Shift+Return 换行"
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.isRunning {
            Button { model.cancel() } label: {
                Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .help("停止 (Esc)")
            .accessibilityLabel("停止生成")
        } else {
            Button { model.sendDraft() } label: {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(ShortcutStore.shared.shortcut(for: .send))
            .help("发送 (Return)")
            .accessibilityLabel("发送")
        }
    }
}

/// 配置选项菜单(模式 / 模型 / 思考强度),取自会话的 configOptions。
struct OptionMenu: View {
    let model: SessionModel
    let category: String
    let icon: String

    var body: some View {
        if let option = model.option(category: category), !option.options.isEmpty {
            Menu {
                ForEach(option.options, id: \.value) { item in
                    Button {
                        model.setConfigOption(option.id, value: item.value)
                    } label: {
                        if option.currentValue.stringValue == item.value {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
            } label: {
                Label(option.currentDisplayName, systemImage: icon)
                    .font(OMFonts.small)
                    .lineLimit(1)
            }
            .fixedSize()
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(OMColors.secondaryText)
            .help(option.name)
        }
    }
}

/// 补全弹层:实心卡片(阅读/交互区域不使用玻璃),键盘与鼠标均可选择。
struct CompletionPopup: View {
    let items: [CompletionItem]
    let selected: Int
    let onPick: (CompletionItem) -> Void

    /// 弹层固定高度(每行 36pt,最多 280pt)
    var height: CGFloat { min(CGFloat(items.count) * 36 + 8, 280) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, isSelected: index == selected)
                            .id(index)
                            .onTapGesture { onPick(item) }
                    }
                }
                .padding(4)
            }
            .onChange(of: selected) { _, value in proxy.scrollTo(value) }
        }
        .frame(width: 420, height: height)
        .background(OMColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OMColors.hairline))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("补全候选")
    }

    private func row(_ item: CompletionItem, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(item.kind))
                .frame(width: 18)
                .foregroundStyle(OMColors.secondaryText)
            Text(item.title).font(OMFonts.body).lineLimit(1)
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func icon(_ kind: CompletionItem.Kind) -> String {
        switch kind {
        case .agentCommand: return "slash.circle"
        case .localCommand: return "terminal"
        case .file: return "doc.text"
        }
    }
}
