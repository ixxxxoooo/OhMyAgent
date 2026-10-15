// @author ygw
// 工具相关视图:工具卡片(Diff / 终端 / 位置 / 子 Agent)、权限卡片、提问表单、终端输出。

import ACPKit
import ChatKit
import DesignSystem
import SwiftUI

// MARK: - 工具卡片

/// 工具卡片:头部显示状态与标题,展开后显示 Diff、终端输出、文本结果与子 Agent 时间线。
struct ToolCardView: View {
    let entry: TimelineEntry
    @Environment(SessionModel.self) private var model
    @State private var expanded: Bool?

    var body: some View {
        if let tool = entry.tool {
            let isExpanded = expanded ?? defaultExpanded(tool)
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded = !isExpanded }
                } label: {
                    header(tool, isExpanded: isExpanded)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tool.title),\(statusText(tool.status))")
                if isExpanded {
                    Divider()
                    details(tool)
                        .padding(12)
                }
            }
            .omSolidCard(cornerRadius: 10)
        }
    }

    /// 默认展开策略:有 Diff、运行中的终端、有子 Agent 时展开。
    private func defaultExpanded(_ tool: ToolCall) -> Bool {
        if entry.childStore != nil, !tool.status.isTerminal { return true }
        for content in tool.content {
            switch content {
            case .diff: return true
            case .terminal(let id): return model.terminals[id]?.isRunning ?? false
            default: continue
            }
        }
        return false
    }

    private func header(_ tool: ToolCall, isExpanded: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.icon(for: tool.kind))
                .frame(width: 16)
                .foregroundStyle(OMColors.secondaryText)
            Text(tool.title.isEmpty ? (tool.name ?? "工具调用") : tool.title)
                .font(OMFonts.small.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let child = entry.childStore {
                OMTag("子任务 \(child.entries.count) 步")
            }
            Spacer(minLength: 8)
            statusView(tool.status)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(OMColors.tertiaryText)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statusView(_ status: ToolStatus) -> some View {
        switch status {
        case .pending: OMStatusDot(.idle)
        case .inProgress: ProgressView().controlSize(.mini)
        case .completed: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.red)
        }
    }

    private func statusText(_ status: ToolStatus) -> String {
        switch status {
        case .pending: return "等待中"
        case .inProgress: return "进行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    @ViewBuilder
    private func details(_ tool: ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !tool.locations.isEmpty {
                FlowLocations(locations: tool.locations) { location in
                    model.viewerRequest = FileViewRequest(path: location.path, line: location.line)
                }
            }
            ForEach(Array(tool.content.enumerated()), id: \.offset) { _, content in
                ToolContentView(content: content)
            }
            if tool.content.isEmpty, let command = tool.rawInput?["command"]?.stringValue {
                Text(command).font(OMFonts.monoSmall).textSelection(.enabled)
            } else if tool.content.isEmpty, let input = tool.rawInput {
                Text(input.compactDescription)
                    .font(OMFonts.monoSmall)
                    .lineLimit(12)
                    .textSelection(.enabled)
            }
            if let child = entry.childStore, !child.entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(child.entries) { item in
                        TimelineEntryView(entry: item)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(OMColors.hairline).frame(width: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func icon(for kind: ToolKind) -> String {
        switch kind {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .delete: return "trash"
        case .move: return "arrow.right.doc.on.clipboard"
        case .search: return "magnifyingglass"
        case .execute: return "terminal"
        case .think: return "brain"
        case .fetch: return "network"
        case .switchMode: return "arrow.triangle.swap"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// 工具内容:文本、Diff、终端。
struct ToolContentView: View {
    let content: ToolCallContent
    @Environment(SessionModel.self) private var model

    var body: some View {
        switch content {
        case .content(let block):
            if let text = block.plainText, !text.isEmpty {
                Text(text)
                    .font(OMFonts.monoSmall)
                    .lineLimit(40)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .diff(let path, let oldText, let newText):
            SnippetDiffView(path: path, oldText: oldText, newText: newText)
        case .terminal(let id):
            if let session = model.terminals[id] {
                TerminalOutputView(session: session)
            } else {
                Label("终端 \(id)", systemImage: "terminal").font(OMFonts.monoSmall)
            }
        case .unknown:
            EmptyView()
        }
    }
}

/// 位置标签行:点击在编辑器面板打开。
struct FlowLocations: View {
    let locations: [ToolLocation]
    let open: (ToolLocation) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(locations.prefix(4).enumerated()), id: \.offset) { _, location in
                Button {
                    open(location)
                } label: {
                    Label(label(location), systemImage: "doc")
                        .font(OMFonts.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(location.path)
            }
            if locations.count > 4 { Text("+\(locations.count - 4)").font(OMFonts.caption).foregroundStyle(OMColors.secondaryText) }
        }
    }

    private func label(_ location: ToolLocation) -> String {
        let name = (location.path as NSString).lastPathComponent
        return location.line.map { "\(name):\($0)" } ?? name
    }
}

// MARK: - 终端输出

/// 终端输出:去除 ANSI 控制序列后以等宽字体显示末尾若干行。
struct TerminalOutputView: View {
    let session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Text(session.command).lineLimit(1).truncationMode(.middle)
                Spacer()
                if session.isRunning {
                    ProgressView().controlSize(.mini)
                } else if let code = session.exitCode {
                    OMTag(code == 0 ? "退出 0" : "退出 \(code)", tint: code == 0 ? .green : .red)
                } else if let signal = session.signal {
                    OMTag(signal, tint: .red)
                }
            }
            .font(OMFonts.monoSmall)
            .foregroundStyle(OMColors.secondaryText)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(Self.display(session.output))
                        .font(OMFonts.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("tail")
                }
                .frame(maxHeight: 220)
                .onChange(of: session.output) { proxy.scrollTo("tail", anchor: .bottom) }
            }
            if session.truncated {
                Text("输出过长,仅显示末尾部分").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 去除 ANSI 转义序列,并只保留末尾 400 行,避免超长文本拖慢布局。
    static func display(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        let lines = stripped.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > 400 ? lines.suffix(400).joined(separator: "\n") : stripped
    }
}

// MARK: - 权限卡片

/// 权限请求卡片:展示 Diff 预览或计划文本,再给出选项。
struct PermissionCard: View {
    let prompt: PermissionPrompt
    let onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: ToolCardView.icon(for: prompt.kind)).foregroundStyle(OMColors.warning)
                Text("需要你的许可").font(OMFonts.small.weight(.semibold))
            }
            Text(prompt.title)
                .font(OMFonts.monoSmall)
                .lineLimit(4)
                .textSelection(.enabled)
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
        .omSolidCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("权限请求:\(prompt.title)")
    }

    @ViewBuilder
    private var preview: some View {
        let contents = prompt.tool.content
        if !contents.isEmpty {
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

/// Agent 提问卡片(AskUserQuestion / MCP 表单 / URL)。
struct ElicitationCard: View {
    let prompt: ElicitationPrompt
    let onFinish: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent 想向你确认", systemImage: "questionmark.bubble")
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
        .omSolidCard()
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
                Image(systemName: selected ? "\(symbol).inset.filled" : symbol)
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
