// @author ixxxxoooo
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
    @State private var dropTargeted = false

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
                // 不再在这里按能力拦截:不支持图片时由 addAttachment 给出提示,而不是悄悄吞掉粘贴/拖入
                acceptsImages: { true },
                onFileURLs: { urls in insertMentions(for: urls) },
                onEdit: updateCompletion,
                onSelectionText: { model.selectedText = $0 },
                // 文件提及内联成 chip,跟在文字后面
                mentionWorkspace: model.workspace
            )
            .frame(height: textHeight)
            HStack(spacing: 6) {
                OptionMenu(model: model, category: "mode", icon: "slider.horizontal.3")
                OptionMenu(model: model, category: "model", icon: "cpu")
                OptionMenu(model: model, category: "thought_level", icon: "brain")
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
        // 整张输入卡片都是图片拖放区(不只是文字那一行),拖入时显示高亮边框
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(OMColors.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                let dropped = await ImageIntake.split(from: providers)
                for image in dropped.images { model.addAttachment(image) }
                if !dropped.files.isEmpty { insertMentions(for: dropped.files) }
            }
            return true
        }
        .overlay(alignment: .top) {
            if dropTargeted {
                Text("松开以添加图片或引用文件")
                    .font(OMFonts.caption).foregroundStyle(OMColors.onAccent)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(OMColors.accent, in: Capsule())
                    .offset(y: -12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    /// 把拖入/粘贴的文件与文件夹转成 `@路径` 提及并插入光标处。
    /// - Parameter urls: 文件或文件夹 URL
    private func insertMentions(for urls: [URL]) {
        let text = DropClassifier.mentions(for: DropClassifier.classify(urls), workspace: model.workspace)
        guard !text.isEmpty else { return }
        controller.insertAtSelection(text)
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
        case .connecting: return model.connectNote ?? String(localized: "正在连接 Agent,可以先输入…")
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
            // 常见输入框做法:占位只提示能做什么,发送键写在发送按钮的提示里
            return String(localized: "输入消息,@ 引用文件,/ 使用命令")
        }
    }

    /// 发送按钮的提示:写明当前的发送键与换行键。
    private var sendHelp: String {
        let commandToSend = sendKey == SendKey.commandEnter.rawValue
        if model.isRunning {
            return commandToSend ? String(localized: "引导当前轮次 (⌘Return);Return 换行") : String(localized: "引导当前轮次 (Return);⌘Return 排到本轮之后")
        }
        return commandToSend ? String(localized: "发送 (⌘Return),Return 换行") : String(localized: "发送 (Return),Shift+Return 换行")
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
                .help(sendHelp)
                .accessibilityLabel(model.isRunning ? String(localized: "引导当前轮次") : String(localized: "发送"))
            }
        }
    }
}

/// 配置选项菜单(模式 / 模型 / 思考强度),取自会话的 configOptions。
/// - 模式:每种模式使用不同的强调色(见 `ModeTone`);
/// - 模型:启用了「Claude Code 模型映射」时,只列出已映射的槽位,显示真实模型名与厂商图标;否则沿用 Claude Code 自带列表。
struct OptionMenu: View {
    let model: SessionModel
    let category: String
    let icon: String
    /// 模型选择弹层是否展开
    @State private var pickerShown = false

    var body: some View {
        if let option = model.option(category: category) {
            let rows = rows(for: option)
            if !rows.isEmpty { menu(option: option, rows: rows) }
        }
    }

    /// 菜单里的一行。
    private struct Row: Identifiable {
        var value: String
        var title: String
        var mapped: MappedModel?
        var id: String { value }
    }

    /// 计算要展示的行。
    private func rows(for option: SessionConfigOption) -> [Row] {
        guard category == "model", !model.mappedModels.isEmpty else {
            return option.options.map { Row(value: $0.value, title: $0.name, mapped: nil) }
        }
        // 映射已启用:未映射的槽位(以及映射之外的选项)不出现
        return option.options.compactMap { item in
            guard let slot = ModelSlot(optionValue: item.value), let mapped = model.mappedModels[slot] else { return nil }
            return Row(value: item.value, title: "\(mapped.displayName) · \(slot.title)", mapped: mapped)
        }
    }

    private func menu(option: SessionConfigOption, rows: [Row]) -> some View {
        let current = option.currentValue.stringValue ?? ""
        let tint = category == "mode" ? Self.color(for: ModeTone.tone(forMode: current)) : OMColors.secondaryText
        if category == "model" { return AnyView(modelPicker(option: option, rows: rows, current: current, tint: tint)) }
        let entries = rows.map { PickEntry(id: $0.value, title: $0.title) }
        return AnyView(
            Button { pickerShown.toggle() } label: { label(option: option, rows: rows, current: current) }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
                .help(option.name)
                .accessibilityLabel(option.name)
                .omPicker(isPresented: $pickerShown, entries: entries, selectedID: current, placeholder: String(localized: "搜索"), width: 200) { entry in
                    model.setConfigOption(option.id, value: entry.id)
                }
        )
    }

    /// 模型选择列表的行(输入区与「编辑并重新发送」共用):映射启用时只列已映射槽位,否则沿用 Agent 自带列表。
    static func modelPickerRows(model: SessionModel, option: SessionConfigOption) -> [ModelPickerRow] {
        let current = option.currentValue.stringValue ?? ""
        if !model.mappedModels.isEmpty {
            return option.options.compactMap { item in
                guard let slot = ModelSlot(optionValue: item.value), let mapped = model.mappedModels[slot] else { return nil }
                return ModelPickerRow(id: item.value, name: "\(mapped.displayName) · \(slot.title)", brand: brand(for: mapped),
                                      copyText: mapped.modelId, isSelected: current == item.value)
            }
        }
        return option.options.map {
            ModelPickerRow(id: $0.value, name: $0.name, brand: BrandIcon.resolve(modelId: $0.name, providerPreset: nil, providerName: $0.name),
                           copyText: $0.value, isSelected: current == $0.value)
        }
    }

    /// 模型选择:点击弹出列表,每行厂商图标 + 模型名 + 复制按钮(NSMenu 项无法放按钮,故用浮层)。
    private func modelPicker(option: SessionConfigOption, rows: [Row], current: String, tint: Color) -> some View {
        let pickerRows = Self.modelPickerRows(model: model, option: option)
        return Button { pickerShown.toggle() } label: {
            label(option: option, rows: rows, current: current)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(option.name)
        .accessibilityLabel(option.name)
        .omPicker(isPresented: $pickerShown, items: pickerRows, selectedID: current, placeholder: String(localized: "搜索模型"), width: 300,
                  row: { ModelPickRowContent(row: $0) }, onSelect: { row in
            model.setConfigOption(option.id, value: row.id)
        })
    }

    @ViewBuilder
    private func label(option: SessionConfigOption, rows: [Row], current: String) -> some View {
        if category == "model", !model.mappedModels.isEmpty {
            let shown = rows.first { $0.value == current }?.mapped ?? model.mappedModels[.main]
            HStack(spacing: 5) {
                if let shown { BrandIconView(Self.brand(for: shown), size: 13) } else { Image.om(icon) }
                Text(shown?.displayName ?? option.currentDisplayName).font(OMFonts.small).lineLimit(1)
            }
        } else {
            if category == "model" {
                // 未启用映射(如官方 Claude):按模型名匹配厂商 logo,不再显示通用芯片图标
                HStack(spacing: 5) {
                    BrandIconView(BrandIcon.resolve(modelId: option.currentDisplayName, providerPreset: nil, providerName: option.currentDisplayName), size: 13)
                    Text(option.currentDisplayName).font(OMFonts.small).lineLimit(1)
                }
            } else {
                Label(option.currentDisplayName, om: icon)
                    .font(OMFonts.small)
                    .lineLimit(1)
            }
        }
    }

    /// 模式色调 → 颜色:优先取主题令牌(强调色/第二强调色/语法关键字色),系统主题下才回退到系统语义色。
    static func color(for tone: ModeTone) -> Color {
        switch tone {
        case .neutral: OMColors.secondaryText
        case .accent: OMColors.accent
        case .green: OMColors.success
        case .blue: OMColors.accent2
        case .purple: OMColors.chart(4)
        case .amber: OMColors.warning
        case .red: OMColors.danger
        }
    }

    /// 映射模型的厂商图标匹配结果。
    static func brand(for mapped: MappedModel) -> BrandIcon {
        BrandIcon.resolve(modelId: mapped.modelId, providerPreset: mapped.presetId, providerName: mapped.providerName)
    }

    /// 菜单项里的小图标(厂商矢量图标;无匹配时用通用芯片图标)。
    static func menuImage(for mapped: MappedModel) -> NSImage {
        if case .vector(let name) = brand(for: mapped), let image = BrandIconRenderer.nsImage(name, size: 14) { return image }
        return OMIconRenderer.nsImage("cpu", size: 14)
    }
}

/// 补全弹层:实心卡片(阅读/交互区域不使用玻璃),键盘与鼠标均可选择;多于一个类别时按类别分节。
struct CompletionPopup: View {
    let items: [CompletionItem]
    let selected: Int
    let onPick: (CompletionItem) -> Void

    /// 一行:分节标题或候选。
    private enum Row: Identifiable {
        case header(String)
        case item(Int, CompletionItem)

        var id: String {
            switch self {
            case .header(let title): return "h-\(title)"
            case .item(_, let item): return item.id
            }
        }
    }

    /// 是否显示分节标题:多于一个类别、且每个类别在列表中连续出现(按相关度交错排列的斜杠命令不分节,避免标题重复)。
    private var showsHeaders: Bool {
        var order: [String] = []
        for item in items where order.last != item.groupTitle { order.append(item.groupTitle) }
        return order.count > 1 && order.count == Set(order).count
    }

    private var rows: [Row] {
        var result: [Row] = []
        var last: String?
        for (index, item) in items.enumerated() {
            if showsHeaders, item.groupTitle != last {
                result.append(.header(item.groupTitle))
                last = item.groupTitle
            }
            result.append(.item(index, item))
        }
        return result
    }

    /// 弹层固定高度(候选行 36pt、标题行 22pt,最多 320pt)
    var height: CGFloat {
        let headers = showsHeaders ? Set(items.map(\.groupTitle)).count : 0
        return min(CGFloat(items.count) * 36 + CGFloat(headers) * 22 + 8, 320)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let title):
                            Text(title)
                                .font(OMFonts.caption)
                                .foregroundStyle(OMColors.tertiaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 22)
                                .accessibilityAddTraits(.isHeader)
                        case .item(let index, let item):
                            self.row(item, isSelected: index == selected)
                                .id(index)
                                .onTapGesture { onPick(item) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(index == selected ? [.isButton, .isSelected] : .isButton)
                        }
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
            if item.kind == .file || item.kind == .folder {
                OMFileIcon(name: (item.title as NSString).lastPathComponent, isDirectory: item.kind == .folder, size: 15)
                    .frame(width: 18)
            } else {
                Image.om(icon(item.kind))
                    .frame(width: 18)
                    .foregroundStyle(OMColors.secondaryText)
            }
            Text(item.title).font(OMFonts.body).lineLimit(1)
            if let badge = item.badge {
                Text(badge)
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(OMColors.pressedFill))
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
        .background(isSelected ? OMColors.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func icon(_ kind: CompletionItem.Kind) -> String {
        switch kind {
        case .agentCommand: return "slash"
        case .localCommand: return "terminal"
        case .file: return "doc.text"
        case .folder: return "folder"
        case .skill: return "sparkles"
        case .customCommand: return "command"
        case .mcpPrompt: return "plug"
        case .subagent: return "bot"
        }
    }
}

/// 输入区下方的上下文条:左侧 Git 分支;右侧连接状态、用量与 Agent 切换(原状态栏功能)。
struct ComposerFooter: View {
    let model: SessionModel
    /// 上下文用量面板是否展开(面板渲染在输入区上方,由对话视图持有)
    @Binding var usageOpen: Bool
    @State private var head: GitHead?

    var body: some View {
        HStack(spacing: 14) {
            if let head {
                BranchSwitcher(workspace: model.workspace, head: head, isBusy: model.isRunning) {
                    Task { await refresh() }
                }
            }
            Spacer()
            footerStatus
            if model.supportsContextBreakdown || model.usage?.used != nil || model.usage?.costAmount != nil || model.contextUsage != nil {
                UsageButton(model: model, isOpen: $usageOpen)
            }
            AgentMenu(model: model)
        }
        .font(OMFonts.caption)
        .foregroundStyle(OMColors.secondaryText)
        .padding(.horizontal, 12)
        .task(id: model.workspace.path) { await refresh() }
        .onChange(of: model.isRunning) { _, running in
            if !running { Task { await refresh() } }
        }
    }

    /// 连接状态:仅在非正常态时提示(连接中/失败),正常时保持安静。
    @ViewBuilder
    private var footerStatus: some View {
        switch model.phase {
        case .connecting:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(model.connectNote == nil ? String(localized: "正在连接…") : String(localized: "正在安装适配器…")) }
        case .failed:
            HStack(spacing: 4) { OMStatusDot(.failure); Text("连接失败").foregroundStyle(OMColors.warning) }
        case .idle:
            HStack(spacing: 4) { OMStatusDot(.idle); Text("未连接") }
        case .ready:
            EmptyView()
        }
    }

    /// 在后台线程读取 HEAD,避免主线程磁盘 I/O。
    private func refresh() async {
        let directory = model.workspace
        head = await Task.detached(priority: .utility) { GitHead.read(at: directory) }.value
    }
}
