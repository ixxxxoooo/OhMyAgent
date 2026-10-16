// @author ygw
// 权限卡片与 Agent 提问表单。(工具行、终端输出等见 ToolRowViews.swift)

import IconKit
import ACPKit
import ChatKit
import DesignSystem
import SwiftUI

// MARK: - 权限卡片

/// 权限请求卡片:展示 Diff 预览或计划文本,再给出选项。
struct PermissionCard: View {
    let prompt: PermissionPrompt
    let onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image.om(prompt.isPlanApproval ? "list-todo" : ToolIcons.symbol(for: prompt.kind)).foregroundStyle(OMColors.warning)
                Text(prompt.isPlanApproval ? "计划待批准" : "需要你的许可").font(OMFonts.small.weight(.semibold))
            }
            if !prompt.isPlanApproval {
                Text(prompt.title)
                    .font(OMFonts.monoSmall)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if let command = prompt.tool.rawInput?["command"]?.stringValue, command != prompt.title {
                Text(command)
                    .font(OMFonts.monoSmall)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            preview
            HStack(spacing: 8) {
                ForEach(prompt.request.options) { option in
                    Button(option.name) { onChoose(option.optionId) }
                        .buttonStyle(.bordered)
                        .tint(option.kind == .allowOnce || option.kind == .allowAlways ? OMColors.accent : nil)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omGlassCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("权限请求:\(prompt.title)")
    }

    @ViewBuilder
    private var preview: some View {
        let contents = prompt.tool.content
        if contents.isEmpty, prompt.isPlanApproval, let plan = prompt.planText {
            AutoHeightScroll(maxHeight: 320) {
                MarkdownView(text: plan).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if !contents.isEmpty {
            AutoHeightScroll(maxHeight: 260) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                        switch content {
                        case .diff(let path, let oldText, let newText):
                            SnippetDiffView(path: path, oldText: oldText, newText: newText)
                        case .content(let block):
                            // 计划(ExitPlanMode)等以 Markdown 文本给出
                            if let text = block.plainText { MarkdownView(text: text) }
                        default:
                            EmptyView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 高度随内容增长、超过上限后滚动的容器(避免固定 maxHeight 造成大片空白)。
struct AutoHeightScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: contentHeight == 0 ? nil : min(contentHeight, maxHeight))
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - 提问表单

/// Agent 提问卡片入口:AskUserQuestion 形态走逐题向导;其余(MCP 表单 / URL)走通用表单。
struct ElicitationCard: View {
    let prompt: ElicitationPrompt
    /// 排在后面等待的提问数量
    var queued = 0
    let onFinish: () -> Void

    var body: some View {
        if let questions = prompt.questions {
            QuestionWizardCard(prompt: prompt, questions: questions, queued: queued, onFinish: onFinish)
        } else {
            GenericElicitationCard(prompt: prompt, onFinish: onFinish)
        }
    }
}

/// 通用表单提问卡片(MCP 表单 / URL 模式)。
struct GenericElicitationCard: View {
    let prompt: ElicitationPrompt
    let onFinish: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent 想向你确认", om: "questionmark.bubble")
                .font(OMFonts.small.weight(.semibold))
            if !prompt.message.isEmpty {
                Text(prompt.message).font(OMFonts.body).textSelection(.enabled)
            }
            switch prompt.mode {
            case .form:
                ForEach(prompt.fields) { field in
                    ElicitFieldView(field: field)
                }
            case .url(let url):
                Text(url.absoluteString)
                    .font(OMFonts.monoSmall)
                    .foregroundStyle(OMColors.secondaryText)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("跳过") { prompt.decline(); onFinish() }
                switch prompt.mode {
                case .form:
                    Button("提交") { prompt.accept(); onFinish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!prompt.canSubmit)
                case .url(let url):
                    Button("打开链接") { openURL(url); prompt.acceptURL(); onFinish() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omGlassCard()
        .accessibilityElement(children: .contain)
    }
}

/// 单个表单字段。
struct ElicitFieldView: View {
    @Bindable var field: ElicitField

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !field.title.isEmpty {
                Text(field.title + (field.isRequired ? " *" : "")).font(OMFonts.small.weight(.semibold))
            }
            if let detail = field.detail, !detail.isEmpty {
                Text(detail).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            }
            switch field.kind {
            case .text:
                TextField("", text: $field.text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            case .number:
                TextField("数字", text: $field.text).textFieldStyle(.roundedBorder)
            case .boolean:
                Toggle("是", isOn: $field.flag).toggleStyle(.switch)
            case .single(let options):
                ForEach(options) { option in
                    optionRow(option, selected: field.selection.contains(option.value), symbol: "circle") {
                        field.selection = [option.value]
                    }
                }
            case .multi(let options):
                ForEach(options) { option in
                    optionRow(option, selected: field.selection.contains(option.value), symbol: "square") {
                        if field.selection.contains(option.value) { field.selection.remove(option.value) } else { field.selection.insert(option.value) }
                    }
                }
            }
        }
    }

    private func optionRow(_ option: ElicitOption, selected: Bool, symbol: String, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 8) {
                Image.om(selected ? "\(symbol).inset.filled" : symbol)
                    .foregroundStyle(selected ? OMColors.accent : OMColors.secondaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title).font(OMFonts.body)
                    if let description = option.description {
                        Text(description).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
