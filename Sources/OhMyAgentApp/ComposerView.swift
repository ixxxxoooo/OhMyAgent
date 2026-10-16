// @author ygw
// 输入区:玻璃浮层,包含输入框、模式/模型菜单、发送与停止按钮。

import IconKit
import ACPKit
import ChatKit
import DesignSystem
import SwiftUI
import WorkbenchKit

/// 输入区视图。
struct ComposerView: View {
    @Bindable var model: SessionModel
    @State private var textHeight: CGFloat = 34
    /// 发送键与运行中发送偏好:仅用于让输入框提示文案随设置刷新
    @AppStorage(ClientPrefs.Key.sendKey) private var sendKey = SendKey.enter.rawValue
    @AppStorage(ClientPrefs.Key.runningSend) private var runningSend = RunningSendMode.steer.rawValue
    @State private var controller = ComposerController()
    @State private var completion: CompletionContext?
    @State private var items: [CompletionItem] = []
    @State private var selected = 0
    @State private var dismissedAt: String?
    @State private var lookup: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments) { item in
                            AttachmentThumbnail(attachment: item, size: 56) { model.removeAttachment(item.id) }
                        }
                    }
                    .padding(.top, 2)
                }
            }
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
                onSubmitAfterTurn: { model.sendDraft(afterTurn: true) },
                onImages: { images in images.forEach { model.addAttachment($0) } },
                acceptsImages: { model.canAttachImages },
                onEdit: updateCompletion,
                onSelectionText: { model.selectedText = $0 }
            )
            .frame(height: textHeight)
            HStack(spacing: 6) {
                OptionMenu(model: model, category: "mode", icon: "slider.horizontal.3")
                OptionMenu(model: model, category: "model", icon: "cpu")
                OptionMenu(model: model, category: "thought_level", icon: "brain")
                if model.canAttachImages {
                    Button {
                        ImageIntake.pickImages().forEach { model.addAttachment($0) }
                    } label: {
                        Image.om("image-plus", size: 12).foregroundStyle(OMColors.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("添加图片(也可粘贴或拖入)")
                    .accessibilityLabel("添加图片")
                }
                MCPPanelButton(model: model)
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
        .animation(omShouldReduceMotion() ? nil : .easeOut(duration: 0.12), value: items.isEmpty)
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
        if context.trigger == .slash || item.kind == .subagent { text += item.insertText.hasSuffix(" ") ? "" : " " }
        completion = nil
        items = []
        controller.replace(range: context.range, with: text)
    }

    private var placeholder: String {
        switch model.phase {
        case .connecting: return String(localized: "正在连接 Agent,可以先输入…")
        case .failed: return String(localized: "Agent 未连接,发送将尝试重新连接")
        default:
            let commandToSend = sendKey == SendKey.commandEnter.rawValue
            if model.isRunning {
                if commandToSend {
                    return model.canSteer && runningSend == RunningSendMode.steer.rawValue
                        ? String(localized: "运行中:⌘Return 引导 \(model.agentName),Return 换行")
                        : String(localized: "运行中:⌘Return 排到本轮之后发送,Return 换行")
                }
                return model.canSteer && runningSend == RunningSendMode.steer.rawValue
                    ? String(localized: "运行中:Return 引导 \(model.agentName),⌘Return 排到本轮之后")
                    : String(localized: "运行中:Return 或 ⌘Return 排到本轮之后发送")
            }
            return commandToSend
                ? String(localized: "向 \(model.agentName) 提问,⌘Return 发送,Return 换行,/ 命令,@ 提及")
                : String(localized: "向 \(model.agentName) 提问,Return 发送,Shift+Return 换行,/ 命令,@ 提及")
        }
    }

    private var hasContent: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty
    }

    @ViewBuilder
    private var sendButton: some View {
        HStack(spacing: 6) {
            if model.isRunning {
                Button { model.cancel() } label: {
                    Image.om("stop.fill", size: 11, weight: .bold).frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("停止 (Esc)")
                .accessibilityLabel("停止生成")
            }
            if !model.isRunning || hasContent {
                Button { model.sendDraft() } label: {
                    Image.om(model.isRunning ? "corner-down-right" : "arrow.up", size: 12, weight: .bold).frame(width: 26, height: 26)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!hasContent)
                .keyboardShortcut(ShortcutStore.shared.shortcut(for: .send))
                .help(model.isRunning ? "引导当前轮次 (Return);⌘Return 排到本轮之后" : "发送 (Return)")
                .accessibilityLabel(model.isRunning ? "引导当前轮次" : "发送")
            }
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
                            Label(item.name, om: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
            } label: {
                Label(option.currentDisplayName, om: icon)
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
    var height: CGFloat { min(CGFloat(items.count) * 36 + 8, 320) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, isSelected: index == selected)
                            .id(index)
                            .onTapGesture { onPick(item) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(index == selected ? [.isButton, .isSelected] : .isButton)
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
            Image.om(icon(item.kind))
                .frame(width: 18)
                .foregroundStyle(OMColors.secondaryText)
            Text(item.title).font(OMFonts.body).lineLimit(1)
            if let badge = item.badge {
                Text(badge)
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
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
        case .agentCommand: return "slash"
        case .localCommand: return "terminal"
        case .file: return "doc.text"
        case .skill: return "sparkles"
        case .customCommand: return "command"
        case .mcpPrompt: return "plug"
        case .subagent: return "bot"
        }
    }
}

/// 输入区下方的上下文条:当前 Git 分支与运行环境(目前仅「本机」)。
struct ComposerFooter: View {
    let model: SessionModel
    @State private var head: GitHead?

    var body: some View {
        HStack(spacing: 14) {
            if let head {
                Label(head.displayName, om: "git-branch")
                    .help("当前分支")
            }
            Menu {
                Button { } label: { Label("本机", om: "checkmark") }
            } label: {
                Label("本机", om: "laptop")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("运行环境")
            Spacer()
        }
        .font(OMFonts.caption)
        .foregroundStyle(OMColors.secondaryText)
        .padding(.horizontal, 12)
        .task(id: model.workspace.path) { await refresh() }
        .onChange(of: model.isRunning) { _, running in
            if !running { Task { await refresh() } }
        }
    }

    /// 在后台线程读取 HEAD,避免主线程磁盘 I/O。
    private func refresh() async {
        let directory = model.workspace
        head = await Task.detached(priority: .utility) { GitHead.read(at: directory) }.value
    }
}
