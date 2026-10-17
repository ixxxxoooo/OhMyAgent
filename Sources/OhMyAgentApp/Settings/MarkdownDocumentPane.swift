// @author ixxxxoooo
// Markdown 文档面板:Skill / 子 Agent / 记忆规则的统一查看与编辑区。
// 默认「预览」(顶部 Obsidian 风格属性面板 + 渲染后的正文),可切到「源码」直接编辑原文。

import ClaudeConfigKit
import DesignSystem
import IconKit
import SwiftUI

/// 面板模式。
enum MarkdownPaneMode: Hashable {
    case preview, source
}

/// 文档面板:模式切换 + 预览/源码。
struct MarkdownDocumentPane: View {
    @Binding var text: String
    /// 只读(例如来自插件的条目):属性与源码都不可改
    var isReadOnly = false
    /// 没有 frontmatter 时是否允许通过「添加属性」新建(普通 CLAUDE.md 不应被悄悄加上头部)
    var allowsCreatingProperties = true
    @State private var mode = MarkdownPaneMode.preview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                OMCompactSegmented(
                    options: [(MarkdownPaneMode.preview, "预览"), (MarkdownPaneMode.source, "源码")],
                    selection: $mode, accessibilityName: String(localized: "显示模式"))
            }
            switch mode {
            case .preview:
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        FrontmatterPropertiesView(text: $text, isReadOnly: isReadOnly, allowsCreating: allowsCreatingProperties)
                        let body = MarkdownDocument(parsing: text).body
                        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("正文为空").font(OMFonts.small).foregroundStyle(OMColors.tertiaryText)
                        } else {
                            MarkdownView(text: body)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .scrollContentBackground(.hidden)
                .background(OMColors.surface, in: RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
            case .source:
                TextEditor(text: $text)
                    .font(OMFonts.mono)
                    .disabled(isReadOnly)
                    .settingsEditorStyle()
            }
        }
    }
}

/// Obsidian 风格的 Properties 面板:图标 + 键 + 值,可折叠;文本/布尔/列表三种控件,支持新增、改名与删除。
struct FrontmatterPropertiesView: View {
    @Binding var text: String
    var isReadOnly = false
    var allowsCreating = true
    @State private var collapsed = false
    @State private var newKey = ""
    @State private var isAdding = false
    @FocusState private var addFocused: Bool

    private var document: MarkdownDocument { MarkdownDocument(parsing: text) }

    var body: some View {
        let doc = document
        let properties = doc.properties
        if !properties.isEmpty || (!isReadOnly && allowsCreating) {
            VStack(alignment: .leading, spacing: 6) {
                header(count: properties.count)
                if !collapsed {
                    ForEach(properties) { property in
                        PropertyRow(property: property, isReadOnly: isReadOnly,
                                    onChange: { change in mutate(change) })
                    }
                    if !isReadOnly, doc.hasFrontmatter || allowsCreating { addRow }
                }
            }
            .padding(10)
            .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
        }
    }

    private func header(count: Int) -> some View {
        Button { omWithAnimation { collapsed.toggle() } } label: {
            HStack(spacing: 6) {
                Image.om(collapsed ? "chevron-right" : "chevron-down", size: 11)
                Text("属性").font(OMFonts.small.weight(.medium))
                if count > 0 { Text("\(count)").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText) }
                Spacer()
            }
            .foregroundStyle(OMColors.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed ? String(localized: "展开属性") : String(localized: "折叠属性"))
    }

    @ViewBuilder
    private var addRow: some View {
        if isAdding {
            HStack(spacing: 8) {
                Image.om("plus", size: 12).foregroundStyle(OMColors.tertiaryText).frame(width: 16)
                TextField("", text: $newKey, prompt: Text("属性名,回车确认"))
                    .textFieldStyle(.plain)
                    .font(OMFonts.small)
                    .focused($addFocused)
                    .onSubmit(commitNewKey)
                    .onExitCommand { isAdding = false; newKey = "" }
                Button("取消") { isAdding = false; newKey = "" }.buttonStyle(.plain).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            }
            .onAppear { addFocused = true }
        } else {
            Button { isAdding = true } label: {
                Label("添加属性", om: "plus").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            }
            .buttonStyle(.plain)
        }
    }

    private func commitNewKey() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        defer { isAdding = false; newKey = "" }
        guard !key.isEmpty else { return }
        mutate { $0.addProperty(key: key) }
    }

    /// 对文档做一次修改并写回文本。
    private func mutate(_ change: (inout MarkdownDocument) -> Void) {
        guard !isReadOnly else { return }
        var doc = document
        change(&doc)
        let rendered = doc.render()
        if rendered != text { text = rendered }
    }
}

/// 单个属性行。
private struct PropertyRow: View {
    let property: MarkdownDocument.Property
    let isReadOnly: Bool
    let onChange: ((inout MarkdownDocument) -> Void) -> Void
    @State private var hovering = false
    @State private var keyDraft = ""
    @State private var listDraft = ""
    @State private var renaming = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image.om(icon, size: 12)
                .foregroundStyle(OMColors.tertiaryText)
                .frame(width: 16, height: 22)
            keyView
            valueEditor
            if !isReadOnly {
                Button { onChange { $0.removeKey(property.key) } } label: { Image.om("x", size: 11) }
                    .buttonStyle(.plain)
                    .foregroundStyle(OMColors.tertiaryText)
                    .frame(width: 18, height: 22)
                    .opacity(hovering ? 1 : 0)
                    .help("删除属性")
                    .accessibilityLabel(String(localized: "删除属性"))
            }
        }
        .onHover { hovering = $0 }
        .onAppear { keyDraft = property.key }
        .onChange(of: property.key) { _, new in keyDraft = new }
    }

    /// 属性名:默认是静态文字(避免弹窗一打开就聚焦在第一个输入框);双击或右键「重命名」进入编辑。
    @ViewBuilder
    private var keyView: some View {
        Group {
            if renaming {
                TextField("", text: $keyDraft)
                    .textFieldStyle(.plain)
                    .focused($keyFocused)
                    .onSubmit { renameIfNeeded(); renaming = false }
                    .onExitCommand { keyDraft = property.key; renaming = false }
                    .onChange(of: keyFocused) { _, focused in if !focused { renameIfNeeded(); renaming = false } }
                    .onAppear { keyFocused = true }
                    .accessibilityLabel(String(localized: "属性名"))
            } else {
                Text(verbatim: property.key)
                    .onTapGesture(count: 2) { if !isReadOnly { renaming = true } }
                    .contextMenu {
                        if !isReadOnly { Button("重命名") { renaming = true } }
                    }
            }
        }
        .font(OMFonts.small)
        .foregroundStyle(OMColors.secondaryText)
        .frame(width: 130, alignment: .leading)
        .frame(height: 22)
    }

    private var icon: String {
        switch property.kind {
        case .text: return property.key == "description" ? "text-align-start" : "type"
        case .bool: return "toggle-left"
        case .list: return "list"
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch property.kind {
        case .text:
            TextField("", text: Binding(
                get: { property.text },
                set: { value in onChange { $0.setValue(property.key, value) } }
            ), prompt: Text("空"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(OMFonts.small)
                .lineLimit(1...6)
                .disabled(isReadOnly)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 22)
        case .bool:
            Toggle("", isOn: Binding(
                get: { property.text == "true" },
                set: { value in onChange { $0.setBool(property.key, value) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(isReadOnly)
            .frame(height: 22)
            .accessibilityLabel(property.key)
            Spacer(minLength: 0)
        case .list:
            FlowLayout(spacing: 5) {
                ForEach(Array(property.items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 3) {
                        Text(verbatim: item).font(OMFonts.caption)
                        if !isReadOnly {
                            Button { remove(at: index) } label: { Image.om("x", size: 9) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(String(localized: "删除 \(item)"))
                        }
                    }
                    .foregroundStyle(OMColors.secondaryText)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(OMColors.selectedFill, in: OMPillShape())
                }
                if !isReadOnly {
                    TextField("", text: $listDraft, prompt: Text("添加…"))
                        .textFieldStyle(.plain)
                        .font(OMFonts.caption)
                        .frame(width: 80, height: 20)
                        .onSubmit(appendItem)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 22)
        }
    }

    private func renameIfNeeded() {
        let new = keyDraft.trimmingCharacters(in: .whitespaces)
        guard new != property.key else { return }
        var accepted = false
        onChange { accepted = $0.renameKey(property.key, to: new) }
        if !accepted { keyDraft = property.key }
    }

    private func appendItem() {
        let item = listDraft.trimmingCharacters(in: .whitespaces)
        listDraft = ""
        guard !item.isEmpty else { return }
        onChange { $0.setList(property.key, property.items + [item]) }
    }

    private func remove(at index: Int) {
        var items = property.items
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        onChange { $0.setList(property.key, items) }
    }
}

/// 自动换行的横向流式布局(标签列表用)。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
